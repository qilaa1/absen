-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Waktu pembuatan: 16 Jun 2025 pada 22.09
-- Versi server: 10.4.32-MariaDB
-- Versi PHP: 8.1.25

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `absen`
--

DELIMITER $$
--
-- Prosedur
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `reset_database_tables` ()   BEGIN
    -- Nonaktifkan pemeriksaan foreign key terlebih dahulu
    SET FOREIGN_KEY_CHECKS = 0;

    -- Kosongkan tabel absensi
    TRUNCATE TABLE absensi;

    -- Kosongkan tabel log_akses
    TRUNCATE TABLE log_akses;

    -- Aktifkan kembali pemeriksaan foreign key
    SET FOREIGN_KEY_CHECKS = 1;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `update_attendance` ()   BEGIN
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
-- Struktur dari tabel `absensi`
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

--
-- Dumping data untuk tabel `absensi`
--

INSERT INTO `absensi` (`id`, `pegawai_id`, `jadwal_shift_id`, `waktu_masuk`, `waktu_keluar`, `kode_unik`, `status_kehadiran`, `keterangan`, `tanggal`) VALUES
(23, 1, 1, '09:00:54', '00:00:00', 'Rd2SOF', 'terlambat', NULL, '2025-06-13 17:00:00'),
(24, 2, 2, '09:02:20', '09:07:37', 'NekrHm', 'hadir', NULL, '2025-06-13 17:00:00');

-- --------------------------------------------------------

--
-- Struktur dari tabel `cuti`
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
-- Trigger `cuti`
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
-- Stand-in struktur untuk tampilan `cuti_disetujui`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Stand-in struktur untuk tampilan `cuti_ditolak`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Stand-in struktur untuk tampilan `cuti_view`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Struktur dari tabel `divisi`
--

CREATE TABLE `divisi` (
  `id` int(11) NOT NULL,
  `nama_divisi` varchar(50) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Dumping data untuk tabel `divisi`
--

INSERT INTO `divisi` (`id`, `nama_divisi`, `created_at`) VALUES
(1, 'IT', '2024-10-23 02:54:41'),
(2, 'HR', '2024-10-23 02:54:41'),
(3, 'Finance', '2024-10-23 02:54:41'),
(4, 'Marketing', '2024-10-23 02:54:41');

--
-- Trigger `divisi`
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
-- Struktur dari tabel `izin`
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
-- Trigger `izin`
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
-- Stand-in struktur untuk tampilan `izin_disetujui`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Stand-in struktur untuk tampilan `izin_ditolak`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Struktur dari tabel `jadwal_shift`
--

CREATE TABLE `jadwal_shift` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `shift_id` int(11) NOT NULL,
  `tanggal` date NOT NULL,
  `status` enum('aktif','nonaktif') DEFAULT 'aktif'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Dumping data untuk tabel `jadwal_shift`
--

INSERT INTO `jadwal_shift` (`id`, `pegawai_id`, `shift_id`, `tanggal`, `status`) VALUES
(1, 1, 75591, '2025-06-14', 'aktif'),
(2, 2, 75591, '2025-06-14', 'aktif');

--
-- Trigger `jadwal_shift`
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
-- Struktur dari tabel `log_akses`
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

--
-- Dumping data untuk tabel `log_akses`
--

INSERT INTO `log_akses` (`id`, `user_id`, `waktu`, `ip_address`, `device_info`, `status`, `device_hash`, `device_details`) VALUES
(127828, 376804, '2025-06-14 09:02:42', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(130791, 376804, '2025-06-14 09:06:47', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(185718, 992335, '2025-06-14 09:03:58', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(189144, 992335, '2025-06-14 09:07:50', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(218050, 376804, '2025-06-14 08:59:45', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(292035, 992334, '2025-06-14 09:04:05', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(466760, 992335, '2025-06-14 09:06:43', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(482022, 992335, '2025-06-14 09:02:25', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(499599, 376804, '2025-06-14 08:59:17', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(506523, 992334, '2025-06-14 08:59:56', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(529669, 376804, '2025-06-14 09:01:13', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(578766, 992334, '2025-06-14 09:05:37', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(589872, 376804, '2025-06-14 09:00:16', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(590327, 376804, '2025-06-14 09:07:14', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(590452, 992335, '2025-06-14 09:05:42', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(614978, 376804, '2025-06-14 09:03:20', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(655243, 376804, '2025-06-14 08:55:06', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(663462, 992334, '2025-06-16 22:38:50', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(665711, 992334, '2025-06-14 09:01:09', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(715870, 992335, '2025-06-14 09:07:19', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(717992, 992334, '2025-06-14 08:59:48', '::1', 'Google Chrome | Windows', 'first_registration', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(827786, 992335, '2025-06-14 09:01:55', '::1', 'Google Chrome | Windows', 'first_registration', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(842994, 376804, '2025-06-14 09:00:00', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(886664, 992334, '2025-06-14 09:07:57', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(934990, 992335, '2025-06-14 09:03:24', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(936336, 376804, '2025-06-14 08:54:28', '::1', 'Google Chrome | Windows', 'first_registration', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}'),
(961993, 376804, '2025-06-14 09:01:53', '::1', 'Google Chrome | Windows', 'logout', 'c7405780fe10b9502cf805ed079399263821488a2d5b32b3868ae8581722f759', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"false\"}'),
(972791, 992334, '2025-06-14 09:00:20', '::1', 'Google Chrome | Windows', 'login', 'a2c78f7cc9835ae1627b99b5083e8099bfb906b9c90cd362c0c1967b74225f31', '{\"platform\":\"Windows NT 10.0; Win64; x64\",\"screen\":\"<script>document.write(screen.width+\\\"x\\\"+screen.height+\\\"x\\\"+screen.colorDepth);<\\/script>\",\"timezone\":\"Asia\\/Jakarta\",\"languages\":\"id,en;q=0.9,en-US;q=0.8,pt-BR;q=0.7,pt;q=0.6\",\"HTTP_ACCEPT\":\"text\\/html,application\\/xhtml+xml,application\\/xml;q=0.9,image\\/avif,image\\/webp,image\\/apng,*\\/*;q=0.8,application\\/signed-exchange;v=b3;q=0.7\",\"HTTP_ACCEPT_ENCODING\":\"gzip, deflate, br, zstd\",\"is_mobile\":\"true\"}');

-- --------------------------------------------------------

--
-- Struktur dari tabel `otp_code`
--

CREATE TABLE `otp_code` (
  `id` int(11) NOT NULL,
  `otp_code` char(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Dumping data untuk tabel `otp_code`
--

INSERT INTO `otp_code` (`id`, `otp_code`) VALUES
(992336, '854070'),
(992337, '000000'),
(992338, '000000'),
(992339, '850404'),
(992340, '000000'),
(992341, '886003'),
(992342, '000000'),
(992343, '000000');

-- --------------------------------------------------------

--
-- Struktur dari tabel `pegawai`
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
-- Dumping data untuk tabel `pegawai`
--

INSERT INTO `pegawai` (`id`, `user_id`, `divisi_id`, `status_aktif`, `hari_libur`, `created_at`, `updated_at`) VALUES
(1, 992334, 1, 'aktif', 'minggu', '2025-06-14 01:59:40', '2025-06-14 01:59:40'),
(2, 992335, 3, 'aktif', 'minggu', '2025-06-14 02:01:49', '2025-06-14 02:01:49');

--
-- Trigger `pegawai`
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
-- Stand-in struktur untuk tampilan `perizinan_setuju_tolak`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Stand-in struktur untuk tampilan `perizinan_view`
-- (Lihat di bawah untuk tampilan aktual)
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
-- Struktur dari tabel `qr_code`
--

CREATE TABLE `qr_code` (
  `id` int(11) NOT NULL,
  `pegawai_id` int(11) NOT NULL,
  `kode_unik` varchar(20) NOT NULL,
  `created_at` datetime NOT NULL,
  `is_used` tinyint(1) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `qr_code`
--

INSERT INTO `qr_code` (`id`, `pegawai_id`, `kode_unik`, `created_at`, `is_used`) VALUES
(4274, 1, '5PW77a', '2025-06-14 09:07:59', 0);

-- --------------------------------------------------------

--
-- Struktur dari tabel `shift`
--

CREATE TABLE `shift` (
  `id` int(11) NOT NULL,
  `nama_shift` varchar(50) NOT NULL,
  `jam_masuk` time NOT NULL,
  `jam_keluar` time NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

--
-- Dumping data untuk tabel `shift`
--

INSERT INTO `shift` (`id`, `nama_shift`, `jam_masuk`, `jam_keluar`) VALUES
(75589, 'Siang', '08:00:00', '12:00:00'),
(75590, 'Malam', '20:00:00', '21:00:00'),
(75591, 'Pagi', '08:35:00', '09:02:00');

-- --------------------------------------------------------

--
-- Struktur dari tabel `users`
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

--
-- Dumping data untuk tabel `users`
--

INSERT INTO `users` (`id`, `username`, `password`, `nama_lengkap`, `jenis_kelamin`, `email`, `role`, `no_telp`, `id_otp`, `created_at`, `updated_at`) VALUES
(376804, 'qila', '$2y$10$lSqT1gjQ9ZTHjxvfzqIQDuImSOH0NdgX21ax5MZ.BVwECNvLrVR2W', 'qil a', 'laki', 'aqiilahcahya.07@gmail.com', 'owner', '083111535157', 992336, '2025-05-11 17:40:01', '2025-05-11 17:40:01'),
(992334, 'fika', '$2y$10$hW5rwG9Bs8cUqPaPOooWPuQKWNT7s18GwTXgrE8/v0WvUtPwFxLtS', 'fika', 'perempuan', 'aqiilah.210170162@mhs.unimal.ac.id', 'karyawan', '0822564738767', 992342, '2025-06-14 01:59:40', '2025-06-14 01:59:40'),
(992335, 'kiki', '$2y$10$lVrxhNBdfRFfZPoHSRNz8uqzLGUUzrMGTtBTkh9l5r2bfdiLv6Zv.', 'kiki', 'perempuan', 'cahyaaqiilah@gmail.com', 'karyawan', '082256473876', 992343, '2025-06-14 02:01:49', '2025-06-14 02:01:49');

-- --------------------------------------------------------

--
-- Struktur untuk view `cuti_disetujui`
--
DROP TABLE IF EXISTS `cuti_disetujui`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `cuti_disetujui`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`cuti`.`pegawai_id` = `pegawai`.`id`)) join `users` on(`pegawai`.`user_id` = `users`.`id`)) WHERE `cuti`.`status` = 'disetujui' ;

-- --------------------------------------------------------

--
-- Struktur untuk view `cuti_ditolak`
--
DROP TABLE IF EXISTS `cuti_ditolak`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `cuti_ditolak`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`cuti`.`pegawai_id` = `pegawai`.`id`)) join `users` on(`pegawai`.`user_id` = `users`.`id`)) WHERE `cuti`.`status` = 'ditolak' ;

-- --------------------------------------------------------

--
-- Struktur untuk view `cuti_view`
--
DROP TABLE IF EXISTS `cuti_view`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `cuti_view`  AS SELECT `users`.`nama_lengkap` AS `nama_staff`, `cuti`.`tanggal_mulai` AS `tanggal_mulai`, `cuti`.`tanggal_selesai` AS `tanggal_selesai`, `cuti`.`durasi_cuti` AS `durasi_cuti`, `cuti`.`keterangan` AS `keterangan`, `cuti`.`status` AS `status` FROM ((`cuti` join `pegawai` on(`pegawai`.`id` = `cuti`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) ;

-- --------------------------------------------------------

--
-- Struktur untuk view `izin_disetujui`
--
DROP TABLE IF EXISTS `izin_disetujui`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `izin_disetujui`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` = 'disetujui' ;

-- --------------------------------------------------------

--
-- Struktur untuk view `izin_ditolak`
--
DROP TABLE IF EXISTS `izin_ditolak`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `izin_ditolak`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` = 'ditolak' ;

-- --------------------------------------------------------

--
-- Struktur untuk view `perizinan_setuju_tolak`
--
DROP TABLE IF EXISTS `perizinan_setuju_tolak`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `perizinan_setuju_tolak`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) WHERE `izin`.`status` in ('disetujui','ditolak') ;

-- --------------------------------------------------------

--
-- Struktur untuk view `perizinan_view`
--
DROP TABLE IF EXISTS `perizinan_view`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `perizinan_view`  AS SELECT `users`.`nama_lengkap` AS `nama_lengkap`, `izin`.`tanggal` AS `tanggal`, `izin`.`jenis_izin` AS `jenis_izin`, `izin`.`keterangan` AS `keterangan`, `izin`.`status` AS `status` FROM ((`izin` join `pegawai` on(`pegawai`.`id` = `izin`.`pegawai_id`)) join `users` on(`users`.`id` = `pegawai`.`user_id`)) ;

--
-- Indexes for dumped tables
--

--
-- Indeks untuk tabel `absensi`
--
ALTER TABLE `absensi`
  ADD PRIMARY KEY (`id`),
  ADD KEY `karyawan_id` (`pegawai_id`),
  ADD KEY `jadwal_shift_id` (`jadwal_shift_id`);

--
-- Indeks untuk tabel `cuti`
--
ALTER TABLE `cuti`
  ADD PRIMARY KEY (`id`),
  ADD KEY `pegawai_id` (`pegawai_id`);

--
-- Indeks untuk tabel `divisi`
--
ALTER TABLE `divisi`
  ADD PRIMARY KEY (`id`);

--
-- Indeks untuk tabel `izin`
--
ALTER TABLE `izin`
  ADD PRIMARY KEY (`id`),
  ADD KEY `pegawai_id` (`pegawai_id`);

--
-- Indeks untuk tabel `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  ADD PRIMARY KEY (`id`),
  ADD KEY `karyawan_id` (`pegawai_id`),
  ADD KEY `shift_id` (`shift_id`);

--
-- Indeks untuk tabel `log_akses`
--
ALTER TABLE `log_akses`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`);

--
-- Indeks untuk tabel `otp_code`
--
ALTER TABLE `otp_code`
  ADD PRIMARY KEY (`id`);

--
-- Indeks untuk tabel `pegawai`
--
ALTER TABLE `pegawai`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `divisi_id` (`divisi_id`);

--
-- Indeks untuk tabel `qr_code`
--
ALTER TABLE `qr_code`
  ADD PRIMARY KEY (`id`),
  ADD KEY `pegawai_id` (`pegawai_id`);

--
-- Indeks untuk tabel `shift`
--
ALTER TABLE `shift`
  ADD PRIMARY KEY (`id`);

--
-- Indeks untuk tabel `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `username` (`username`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `id_otp` (`id_otp`);

--
-- AUTO_INCREMENT untuk tabel yang dibuang
--

--
-- AUTO_INCREMENT untuk tabel `absensi`
--
ALTER TABLE `absensi`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=25;

--
-- AUTO_INCREMENT untuk tabel `cuti`
--
ALTER TABLE `cuti`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=654325;

--
-- AUTO_INCREMENT untuk tabel `divisi`
--
ALTER TABLE `divisi`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=234237;

--
-- AUTO_INCREMENT untuk tabel `izin`
--
ALTER TABLE `izin`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12314140;

--
-- AUTO_INCREMENT untuk tabel `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT untuk tabel `log_akses`
--
ALTER TABLE `log_akses`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=986452;

--
-- AUTO_INCREMENT untuk tabel `otp_code`
--
ALTER TABLE `otp_code`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=992344;

--
-- AUTO_INCREMENT untuk tabel `pegawai`
--
ALTER TABLE `pegawai`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=26;

--
-- AUTO_INCREMENT untuk tabel `qr_code`
--
ALTER TABLE `qr_code`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4275;

--
-- AUTO_INCREMENT untuk tabel `shift`
--
ALTER TABLE `shift`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=75592;

--
-- AUTO_INCREMENT untuk tabel `users`
--
ALTER TABLE `users`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=992336;

--
-- Ketidakleluasaan untuk tabel pelimpahan (Dumped Tables)
--

--
-- Ketidakleluasaan untuk tabel `absensi`
--
ALTER TABLE `absensi`
  ADD CONSTRAINT `absensi_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`),
  ADD CONSTRAINT `absensi_ibfk_2` FOREIGN KEY (`jadwal_shift_id`) REFERENCES `jadwal_shift` (`id`);

--
-- Ketidakleluasaan untuk tabel `cuti`
--
ALTER TABLE `cuti`
  ADD CONSTRAINT `cuti_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`);

--
-- Ketidakleluasaan untuk tabel `izin`
--
ALTER TABLE `izin`
  ADD CONSTRAINT `izin_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`);

--
-- Ketidakleluasaan untuk tabel `jadwal_shift`
--
ALTER TABLE `jadwal_shift`
  ADD CONSTRAINT `jadwal_shift_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`),
  ADD CONSTRAINT `jadwal_shift_ibfk_2` FOREIGN KEY (`shift_id`) REFERENCES `shift` (`id`);

--
-- Ketidakleluasaan untuk tabel `log_akses`
--
ALTER TABLE `log_akses`
  ADD CONSTRAINT `log_akses_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`);

--
-- Ketidakleluasaan untuk tabel `pegawai`
--
ALTER TABLE `pegawai`
  ADD CONSTRAINT `pegawai_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`),
  ADD CONSTRAINT `pegawai_ibfk_2` FOREIGN KEY (`divisi_id`) REFERENCES `divisi` (`id`);

--
-- Ketidakleluasaan untuk tabel `qr_code`
--
ALTER TABLE `qr_code`
  ADD CONSTRAINT `qr_code_ibfk_1` FOREIGN KEY (`pegawai_id`) REFERENCES `pegawai` (`id`);

--
-- Ketidakleluasaan untuk tabel `users`
--
ALTER TABLE `users`
  ADD CONSTRAINT `users_ibfk_1` FOREIGN KEY (`id_otp`) REFERENCES `otp_code` (`id`);

DELIMITER $$
--
-- Event
--
CREATE DEFINER=`root`@`localhost` EVENT `auto_clear_database` ON SCHEDULE EVERY 1 YEAR STARTS '2024-11-07 16:54:05' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL reset_database_table();
END$$

CREATE DEFINER=`root`@`localhost` EVENT `auto_insert_absensi_event` ON SCHEDULE EVERY 3 SECOND STARTS '2024-11-07 16:54:05' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL update_attendance();
END$$

DELIMITER ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
