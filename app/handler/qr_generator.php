<?php
ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

session_start();
require '../../app/auth/auth.php'; // Koneksi ke database

// Cek autentikasi
if (!isset($_SESSION['loggedin'])) {
    header("HTTP/1.1 401 Unauthorized");
    echo "Akses ditolak. Anda harus login.";
    exit;
}

// Ambil pegawai_id dari session atau database
if (!isset($_SESSION['pegawai_id'])) {
    $stmt = $pdo->prepare("SELECT id FROM pegawai WHERE user_id = :user_id");
    $stmt->execute(['user_id' => $_SESSION['id']]);
    $pegawai_id = $stmt->fetchColumn();
    $_SESSION['pegawai_id'] = $pegawai_id;
} else {
    $pegawai_id = $_SESSION['pegawai_id'];
}

// Function: Cek apakah kode sudah digunakan di tabel absensi
function isCodeExistsInAbsensi($pdo, $code) {
    $stmt = $pdo->prepare("SELECT COUNT(*) FROM absensi WHERE kode_unik = :kode_unik");
    $stmt->execute(['kode_unik' => $code]);
    return $stmt->fetchColumn() > 0;
}

// Function: Cek apakah tabel qr_code kosong
function isQrCodeTableEmpty($pdo) {
    $stmt = $pdo->query("SELECT COUNT(*) FROM qr_code");
    return $stmt->fetchColumn() == 0;
}

// Function: Ambil kode QR terakhir
function getCurrentCode($pdo) {
    $stmt = $pdo->query("SELECT kode_unik FROM qr_code ORDER BY id DESC LIMIT 1");
    return $stmt->fetchColumn();
}

// Function: Generate kode unik
function generateUniqueCode() {
    $characters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    $length = 6;
    $code = '';
    for ($i = 0; $i < $length; $i++) {
        $code .= $characters[rand(0, strlen($characters) - 1)];
    }
    return $code;
}

// Function: Insert kode ke qr_code
function insertCode($pdo, $code, $pegawai_id) {
    $stmt = $pdo->prepare("INSERT INTO qr_code (kode_unik, pegawai_id, created_at, is_used) 
                           VALUES (:kode_unik, :pegawai_id, NOW(), 0)");
    $stmt->execute([
        'kode_unik' => $code,
        'pegawai_id' => $pegawai_id
    ]);
}

// Function: Update kode terakhir di qr_code
function updateCode($pdo, $code, $pegawai_id) {
    $stmt = $pdo->query("SELECT id FROM qr_code ORDER BY id DESC LIMIT 1");
    $id = $stmt->fetchColumn();

    $stmt = $pdo->prepare("UPDATE qr_code 
                           SET kode_unik = :kode_unik, pegawai_id = :pegawai_id, created_at = NOW(), is_used = 0 
                           WHERE id = :id");
    $stmt->execute([
        'kode_unik' => $code,
        'pegawai_id' => $pegawai_id,
        'id' => $id
    ]);
}

// Mulai proses generate QR code
$generateNew = false;

if (isQrCodeTableEmpty($pdo)) {
    // Jika belum ada kode sebelumnya
    do {
        $newCode = generateUniqueCode();
    } while (isCodeExistsInAbsensi($pdo, $newCode));

    insertCode($pdo, $newCode, $pegawai_id);
    $_SESSION['current_code'] = $newCode;
    $generateNew = true;
} else {
    $currentCode = getCurrentCode($pdo);

    if (isCodeExistsInAbsensi($pdo, $currentCode)) {
        // Jika kode sudah digunakan → buat baru
        do {
            $newCode = generateUniqueCode();
        } while (isCodeExistsInAbsensi($pdo, $newCode));

        updateCode($pdo, $newCode, $pegawai_id);
        $_SESSION['current_code'] = $newCode;
        $generateNew = true;
    } else {
        // Gunakan kode yang belum dipakai
        $_SESSION['current_code'] = $currentCode;
    }
}

// Generate QR URL
$size = '200x200';
$url = "https://api.qrserver.com/v1/create-qr-code/?size={$size}&data=" . urlencode($_SESSION['current_code']);

// Hitung waktu update selanjutnya (misalnya: setiap 1 menit)
$lastUpdate = date('Y-m-d H:i:s');
$nextUpdate = date('Y-m-d H:i:s', strtotime('+1 minute'));

// Return JSON ke client
echo json_encode([
    'qrUrl' => $url,
    'needsUpdate' => $generateNew,
    'lastUpdate' => $lastUpdate,
    'nextUpdate' => $nextUpdate,
    'code' => $_SESSION['current_code']
]);
?>
