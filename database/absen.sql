-- phpMyAdmin SQL Dump
-- version 5.1.1deb5ubuntu1
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Dec 13, 2024 at 10:54 AM
-- Server version: 10.6.18-MariaDB-0ubuntu0.22.04.1
-- PHP Version: 8.1.2-1ubuntu2.20

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `si_hadir`
--

DELIMITER $$
--
-- Procedures
--
CREATE PROCEDURE `reset_database_tables` ()  BEGIN
    -- Nonaktifkan pemeriksaan foreign key terlebih dahulu
    SET FOREIGN_KEY_CHECKS = 0;

    -- Kosongkan tabel absensi
    TRUNCATE TABLE absensi;

    -- Kosongkan tabel log_akses
    TRUNCATE TABLE log_akses;

    -- Aktifkan kembali pemeriksaan foreign key
    SET FOREIGN_KEY_CHECKS = 1;
END$$

CREATE PROCEDURE `update_attendance` ()  BEGIN
    -- Deklarasi variabel untuk iterasi pengguna
    DECLARE done INT DEFAULT FALSE;
    DECLARE curr_pegawai_id INT;
    DECLARE curr_shift_id INT;
    DECLARE curr_jadwal_id INT;
    DECLARE curr_hari_libur VARCHAR(10);
    DECLARE status_kehadiran VARCHAR(10) DEFAULT 'alpha';
    DECLARE hari_ini VARCHAR(10);
    DECLARE tanggal_hari_ini DATE;

    -- Cursor untuk mengambil semua pegawai yang aktif beserta hari liburnya
    DECLARE cur_employees CURSOR FOR 
        SELECT p.id, p.hari_libur
        FROM pegawai p 
        JOIN users u ON p.user_id = u.id 
        WHERE u.role = 'karyawan' AND p.status_aktif = 'aktif';
    
    -- Handler untuk mengatur status selesai ketika cursor habis
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    -- Set timezone ke Asia/Jakarta (GMT+7)
    SET time_zone = '+07:00';

    -- Mendapatkan tanggal hari ini
    SET tanggal_hari_ini = CURRENT_DATE();

    -- Update status tidak_absen_pulang untuk kemarin jika ada entri
    IF EXISTS (
        SELECT 1 
        FROM absensi 
        WHERE DATE(tanggal) = DATE(tanggal_hari_ini - INTERVAL 1 DAY)
    ) THEN
        UPDATE absensi 
        SET status_kehadiran = 'tidak_absen_pulang'
        WHERE DATE(tanggal) = DATE(tanggal_hari_ini - INTERVAL 1 DAY)
        AND waktu_masuk != '00:00:00'
        AND waktu_keluar = '00:00:00';
    END IF;

    -- Mendapatkan nama hari ini dalam bahasa Indonesia
    SET hari_ini = LOWER(
        CASE DAYOFWEEK(tanggal_hari_ini)
            WHEN 1 THEN 'minggu'
            WHEN 2 THEN 'senin'
            WHEN 3 THEN 'selasa'
            WHEN 4 THEN 'rabu'
            WHEN 5 THEN 'kamis'
            WHEN 6 THEN 'jumat'
            WHEN 7 THEN 'sabtu'
        END
    );

    -- Membuka cursor
    OPEN cur_employees;

    -- Memulai loop untuk setiap pegawai
    read_loop: LOOP
        -- Mengambil pegawai berikutnya beserta hari liburnya
        FETCH cur_employees INTO curr_pegawai_id, curr_hari_libur;

        -- Keluar jika tidak ada pegawai lagi
        IF done THEN 
            LEAVE read_loop; 
        END IF;

        -- Memeriksa apakah record jadwal_shift sudah ada untuk hari ini
        IF NOT EXISTS (
            SELECT 1 
            FROM jadwal_shift 
            WHERE pegawai_id = curr_pegawai_id 
            AND tanggal = tanggal_hari_ini
        ) THEN
            -- Mengambil shift_id terakhir yang aktif untuk pegawai ini
            SELECT shift_id INTO curr_shift_id 
            FROM jadwal_shift 
            WHERE pegawai_id = curr_pegawai_id 
            AND status = 'aktif' 
            ORDER BY tanggal DESC LIMIT 1;

            -- Menyisipkan record jadwal_shift baru
            INSERT INTO jadwal_shift (pegawai_id, shift_id, tanggal, status)
            VALUES (
                curr_pegawai_id, 
                IFNULL(curr_shift_id, 1),
                tanggal_hari_ini, 
                'aktif'
            );

            -- Verifikasi apakah penyisipan berhasil
            SET curr_jadwal_id = LAST_INSERT_ID();

            -- Memastikan bahwa jadwal_shift_id baru ada
            IF curr_jadwal_id IS NULL THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Gagal membuat record jadwal_shift.';
            END IF;
        ELSE
            -- Mengambil jadwal_shift id yang ada untuk hari ini
            SELECT id, shift_id INTO curr_jadwal_id, curr_shift_ID
            FROM jadwal_shift 
            WHERE pegawai_id = curr_pegawai_id 
            AND tanggal = tanggal_hari_ini
            AND status = 'aktif' 
            LIMIT 1;
        END IF;

        -- Mengatur status kehadiran default
        SET status_kehadiran = 'alpha';
        
        -- Cek apakah hari ini adalah hari libur pegawai
        IF curr_hari_libur = hari_ini THEN
            SET status_kehadiran = 'libur';
        ELSE
            -- Cek tabel izin jika bukan hari libur
            IF EXISTS (
                SELECT 1 
                FROM izin 
                WHERE pegawai_id = curr_pegawai_id 
                AND tanggal = tanggal_hari_ini
                AND status = 'disetujui'
            ) THEN
                SET status_kehadiran = 'izin';
            ELSEIF EXISTS (
                -- Cek tabel cuti
                SELECT 1 
                FROM cuti 
                WHERE pegawai_id = curr_pegawai_id 
                AND tanggal_hari_ini BETWEEN tanggal_mulai AND tanggal_selesai 
                AND status = 'disetujui'
            ) THEN
                SET status_kehadiran = 'cuti';
            END IF;
        END IF;

        -- Update absensi jika ada izin valid untuk hari ini
        IF status_kehadiran = 'izin' THEN
            UPDATE absensi 
            SET status_kehadiran = 'izin'
            WHERE pegawai_id = curr_pegawai_id 
            AND DATE(tanggal) = tanggal_hari_ini;
        END IF;

        -- Update absensi jika ada cuti valid untuk hari ini
        IF status_kehadiran = 'cuti' THEN
            UPDATE absensi 
            SET status_kehadiran = 'cuti'
            WHERE pegawai_id = curr_pegawai_id 
            AND DATE(tanggal) = tanggal_hari_ini;
        END IF;

        -- Cek apakah sudah ada record absensi untuk hari ini
        IF NOT EXISTS (
            SELECT 1 
            FROM absensi 
            WHERE pegawai_id = curr_pegawai_id 
            AND DATE(tanggal) = tanggal_hari_ini
        ) THEN
            -- Insert record baru hanya jika belum ada
            INSERT INTO absensi (
                pegawai_id, 
                jadwal_shift_id, 
                waktu_masuk, 
                waktu_keluar, 
                kode_unik, 
                status_kehadiran, 
                tanggal
            ) VALUES (
                curr_pegawai_id, 
                curr_jadwal_id, 
                '00:00:00', 
                '00:00:00', 
                '000000', 
                status_kehadiran, 
                tanggal_hari_ini
            );
        END IF;

    END LOOP;

    -- Menutup cursor
    CLOSE cur_employees;

END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `absensi`
--

CREATE TABLE `absensi` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `jadwal_shift_id` int(11) NOT NULL,
  `waktu_masuk` time DEFAULT NULL,
  `waktu_keluar` time DEFAULT NULL,
  `kode_unik` char(6) NOT NULL,
  `status_kehadiran` enum('hadir','terlambat','izin','alpha','cuti','dalam_shift','pulang_dahulu','tidak_absen_pulang','libur') NOT NULL DEFAULT 'alpha',
  `keterangan` text DEFAULT NULL,
  `tanggal` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Table structure for table `cuti`
--

CREATE TABLE `cuti` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `tanggal_mulai` date NOT NULL,
  `tanggal_selesai` date NOT NULL,
  `durasi_cuti` int(11) DEFAULT NULL,
  `keterangan` text DEFAULT NULL,
  `status` enum('pending','disetujui','ditolak') NOT NULL DEFAULT 'pending',
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Triggers `cuti`
--
DELIMITER $$
CREATE TRIGGER `before_cuti_insert` BEFORE INSERT ON `cuti` FOR EACH ROW BEGIN
    SET NEW.id = (
        SELECT COALESCE(MAX(id), 0) + 1
        FROM cuti
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `hitung_durasi_cuti` BEFORE INSERT ON `cuti` FOR EACH ROW BEGIN
    SET NEW.durasi_cuti = DATEDIFF(NEW.tanggal_selesai, NEW.tanggal_mulai);
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `cuti_disetujui`
-- (See below for the actual view)
--
CREATE TABLE `cuti_disetujui` (
`nama_staff` varchar(100)
,`tanggal_mulai` date
,`tanggal_selesai` date
,`durasi_cuti` int(11)
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `cuti_ditolak`
-- (See below for the actual view)
--
CREATE TABLE `cuti_ditolak` (
`nama_staff` varchar(100)
,`tanggal_mulai` date
,`tanggal_selesai` date
,`durasi_cuti` int(11)
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `cuti_view`
-- (See below for the actual view)
--
CREATE TABLE `cuti_view` (
`nama_staff` varchar(100)
,`tanggal_mulai` date
,`tanggal_selesai` date
,`durasi_cuti` int(11)
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Table structure for table `divisi`
--

CREATE TABLE `divisi` (
  `id` int(11) NOT NULL,
  `nama_divisi` varchar(50) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Dumping data for table `divisi`
--

INSERT INTO `divisi` (`id`, `nama_divisi`, `created_at`) VALUES
(1, 'IT', '2024-10-23 02:54:41'),
(2, 'HR', '2024-10-23 02:54:41'),
(3, 'Finance', '2024-10-23 02:54:41'),
(4, 'Marketing', '2024-10-23 02:54:41');

--
-- Triggers `divisi`
--
DELIMITER $$
CREATE TRIGGER `before_divisi_insert` BEFORE INSERT ON `divisi` FOR EACH ROW BEGIN
    SET NEW.id = (
        SELECT COALESCE(MAX(id), 0) + 1
        FROM divisi
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `izin`
--

CREATE TABLE `izin` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `tanggal` date NOT NULL,
  `jenis_izin` enum('keperluan_pribadi','dinas_luar','sakit') NOT NULL,
  `keterangan` text DEFAULT NULL,
  `status` enum('pending','disetujui','ditolak') NOT NULL DEFAULT 'pending',
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Triggers `izin`
--
DELIMITER $$
CREATE TRIGGER `before_izin_insert` BEFORE INSERT ON `izin` FOR EACH ROW BEGIN
    SET NEW.id = (
        SELECT COALESCE(MAX(id), 0) + 1
        FROM izin
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `izin_disetujui`
-- (See below for the actual view)
--
CREATE TABLE `izin_disetujui` (
`nama_lengkap` varchar(100)
,`tanggal` date
,`jenis_izin` enum('keperluan_pribadi','dinas_luar','sakit')
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `izin_ditolak`
-- (See below for the actual view)
--
CREATE TABLE `izin_ditolak` (
`nama_lengkap` varchar(100)
,`tanggal` date
,`jenis_izin` enum('keperluan_pribadi','dinas_luar','sakit')
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Table structure for table `jadwal_shift`
--

CREATE TABLE `jadwal_shift` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `shift_id` int(11) NOT NULL,
  `tanggal` date NOT NULL,
  `status` enum('aktif','nonaktif') DEFAULT 'aktif'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Triggers `jadwal_shift`
--
DELIMITER $$
CREATE TRIGGER `before_jadwal_shift_insert` BEFORE INSERT ON `jadwal_shift` FOR EACH ROW BEGIN
    SET NEW.id = (
        SELECT COALESCE(MAX(id), 0) + 1
        FROM jadwal_shift
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `log_akses`
--

CREATE TABLE `log_akses` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `waktu` datetime DEFAULT NULL,
  `ip_address` varchar(45) NOT NULL,
  `device_info` varchar(255) DEFAULT NULL,
  `status` enum('logout','login','first_registration') DEFAULT NULL,
  `device_hash` varchar(64) DEFAULT NULL,
  `device_details` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Table structure for table `otp_code`
--

CREATE TABLE `otp_code` (
  `id` int(11) NOT NULL,
  `otp_code` char(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Table structure for table `pegawai`
--

CREATE TABLE `pegawai` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `divisi_id` int(11) NOT NULL,
  `status_aktif` enum('aktif','nonaktif') DEFAULT 'aktif',
  `hari_libur` enum('senin','selasa','rabu','kamis','jumat','sabtu','minggu') NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Triggers `pegawai`
--
DELIMITER $$
CREATE TRIGGER `before_pegawai_insert` BEFORE INSERT ON `pegawai` FOR EACH ROW BEGIN
    SET NEW.id = (
        SELECT COALESCE(MAX(id), 0) + 1
        FROM pegawai
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `perizinan_setuju_tolak`
-- (See below for the actual view)
--
CREATE TABLE `perizinan_setuju_tolak` (
`nama_lengkap` varchar(100)
,`tanggal` date
,`jenis_izin` enum('keperluan_pribadi','dinas_luar','sakit')
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `perizinan_view`
-- (See below for the actual view)
--
CREATE TABLE `perizinan_view` (
`nama_lengkap` varchar(100)
,`tanggal` date
,`jenis_izin` enum('keperluan_pribadi','dinas_luar','sakit')
,`keterangan` text
,`status` enum('pending','disetujui','ditolak')
);

-- --------------------------------------------------------

--
-- Table structure for table `qr_code`
--

CREATE TABLE `qr_code` (
  `id` int(11) NOT NULL,
  `kode_unik` char(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Table structure for table `shift`
--

CREATE TABLE `shift` (
  `id` int(11) NOT NULL,
  `nama_shift` varchar(50) NOT NULL,
  `jam_masuk` time NOT NULL,
  `jam_keluar` time NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE `users` (
  `id` int(11) NOT NULL,
  `username` varchar(50) NOT NULL,
  `password` varchar(255) NOT NULL,
  `nama_lengkap` varchar(100) NOT NULL,
  `jenis_kelamin` enum('laki','perempuan') NOT NULL,
  `email` varchar(100) NOT NULL,
  `role` enum('owner','karyawan') NOT NULL,
  `no_telp` varchar(15) DEFAULT NULL,
  `id_otp` int(11) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- --------------------------------------------------------

--
-- Structure for view `cuti_disetujui`
--
DROP TABLE IF EXISTS `cuti_disetujui`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `cuti_disetujui`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`cuti`.`pegawai_id` = `pegawai`.`id`)) join `users` on(`pegawai`.`user_id` = `users`.`id`)) WHERE `cuti`.`status` = 'disetujui' ;

-- --------------------------------------------------------

--
-- Structure for view `cuti_ditolak`
--
DROP TABLE IF EXISTS `cuti_ditolak`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `cuti_ditolak`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`cuti`.`pegawai_id` = `pegawai`.`id`)) join `users` on(`pegawai`.`user_id` = `users`.`id`)) WHERE `cuti`.`status` = 'ditolak' ;

-- --------------------------------------------------------

--
-- Structure for view `cuti_view`
--
DROP TABLE IF EXISTS `cuti_view`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `cuti_view`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`pegawai`.`id` = `cuti`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) ;

-- --------------------------------------------------------

--
-- Structure for view `izin_disetujui`
--
DROP TABLE IF EXISTS `izin_disetujui`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `izin_disetujui`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` = 'disetujui' ;

-- --------------------------------------------------------

--
-- Structure for view `izin_ditolak`
--
DROP TABLE IF EXISTS `izin_ditolak`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `izin_ditolak`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` = 'ditolak' ;

-- --------------------------------------------------------

--
-- Structure for view `perizinan_setuju_tolak`
--
DROP TABLE IF EXISTS `perizinan_setuju_tolak`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `perizinan_setuju_tolak`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` in ('disetujui','ditolak') ;

-- --------------------------------------------------------

--
-- Structure for view `perizinan_view`
--
DROP TABLE IF EXISTS `perizinan_view`;

CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `perizinan_view`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `absensi`
--
ALTER TABLE `absensi`
  ADD PRIMARY KEY (`id`),
  ADD KEY `karyawan_id` (`pegawai_id`),
  ADD KEY `jadwal_shift_id` (`jadwal_shift_id`);

--
-- Indexes for table `cuti`
--
ALTER TABLE `cuti`
  ADD PRIMARY KEY (`id`),
  ADD KEY `pegawai_id` (`pegawai_id`);

--
-- Indexes for table `divisi`
--
ALTER TABLE `divisi`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `izin`
--
ALTER TABLE `izin`
  ADD PRIMARY KEY (`id`),
  ADD KEY `pegawai_id` (`pegawai_id`);

--
-- Indexes for table `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  ADD PRIMARY KEY (`id`),
  ADD KEY `karyawan_id` (`pegawai_id`),
  ADD KEY `shift_id` (`shift_id`);

--
-- Indexes for table `log_akses`
--
ALTER TABLE `log_akses`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`);

--
-- Indexes for table `otp_code`
--
ALTER TABLE `otp_code`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `pegawai`
--
ALTER TABLE `pegawai`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `divisi_id` (`divisi_id`);

--
-- Indexes for table `qr_code`
--
ALTER TABLE `qr_code`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `shift`
--
ALTER TABLE `shift`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `username` (`username`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `id_otp` (`id_otp`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `absensi`
--
ALTER TABLE `absensi`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=21;

--
-- AUTO_INCREMENT for table `cuti`
--
ALTER TABLE `cuti`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=654325;

--
-- AUTO_INCREMENT for table `divisi`
--
ALTER TABLE `divisi`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=234237;

--
-- AUTO_INCREMENT for table `izin`
--
ALTER TABLE `izin`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12314140;

--
-- AUTO_INCREMENT for table `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT for table `log_akses`
--
ALTER TABLE `log_akses`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=996008;

--
-- AUTO_INCREMENT for table `otp_code`
--
ALTER TABLE `otp_code`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=992336;

--
-- AUTO_INCREMENT for table `pegawai`
--
ALTER TABLE `pegawai`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=26;

--
-- AUTO_INCREMENT for table `qr_code`
--
ALTER TABLE `qr_code`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=121;

--
-- AUTO_INCREMENT for table `shift`
--
ALTER TABLE `shift`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=75589;

--
-- AUTO_INCREMENT for table `users`
--
ALTER TABLE `users`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=992329;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `absensi`
--
ALTER TABLE `absensi`
  ADD CONSTRAINT `absensi_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`),
  ADD CONSTRAINT `absensi_ibfk_2` FOREIGN KEY (`jadwal_shift_id`) REFERENCES `jadwal_shift` (`id`);

--
-- Constraints for table `cuti`
--
ALTER TABLE `cuti`
  ADD CONSTRAINT `cuti_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`);

--
-- Constraints for table `izin`
--
ALTER TABLE `izin`
  ADD CONSTRAINT `izin_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`);

--
-- Constraints for table `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  ADD CONSTRAINT `jadwal_shift_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`),
  ADD CONSTRAINT `jadwal_shift_ibfk_2` FOREIGN KEY (`shift_id`) REFERENCES `shift` (`id`);

--
-- Constraints for table `log_akses`
--
ALTER TABLE `log_akses`
  ADD CONSTRAINT `log_akses_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`);

--
-- Constraints for table `pegawai`
--
ALTER TABLE `pegawai`
  ADD CONSTRAINT `pegawai_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`),
  ADD CONSTRAINT `pegawai_ibfk_2` FOREIGN KEY (`divisi_id`) REFERENCES `divisi` (`id`);

--
-- Constraints for table `users`
--
ALTER TABLE `users`
  ADD CONSTRAINT `users_ibfk_1` FOREIGN KEY (`id_otp`) REFERENCES `otp_code` (`id`);

DELIMITER $$
--
-- Events
--
CREATE EVENT `auto_clear_database` ON SCHEDULE EVERY 1 YEAR STARTS '2024-11-07 16:54:05' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL reset_database_table();
END$$

CREATE EVENT `auto_insert_absensi_event` ON SCHEDULE EVERY 3 SECOND STARTS '2024-11-07 16:54:05' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL update_attendance();
END$$

DELIMITER ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;