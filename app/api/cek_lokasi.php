<?php
header('Content-Type: application/json');

// Ambil data lokasi dari frontend
$data = json_decode(file_get_contents('php://input'), true);

// Validasi input
if (!isset($data['lat']) || !isset($data['lon'])) {
    echo json_encode(['allowed' => false, 'message' => 'Lokasi tidak ditemukan.']);
    exit();
}

$userLat = $data['lat'];
$userLon = $data['lon'];
 
// Lokasi kantor desa (contoh) — GANTI dengan koordinat sebenarnya
$kantorLat =3.7571051;  // Latitude kantor kamu
$kantorLon =98.2714716; // Longitude kantor kamu

// Hitung jarak menggunakan rumus Haversine
function hitungJarak($lat1, $lon1, $lat2, $lon2) {
    $R = 6371; // Radius bumi dalam KM
    $dLat = deg2rad($lat2 - $lat1);
    $dLon = deg2rad($lon2 - $lon1);
    $a = sin($dLat / 2) * sin($dLat / 2) +
         cos(deg2rad($lat1)) * cos(deg2rad($lat2)) *
         sin($dLon / 2) * sin($dLon / 2);
    $c = 2 * atan2(sqrt($a), sqrt(1 - $a));
    return $R * $c;
}

// Cek jarak pengguna ke kantor
$jarak = hitungJarak($userLat, $userLon, $kantorLat, $kantorLon);

// Dalam radius 0.1 km (100 meter)
$isAllowed = $jarak <= 0.6;

echo json_encode([
    'allowed' => $isAllowed,
    'distance_km' => round($jarak, 4),
    'message' => $isAllowed ? 'Akses diizinkan.' : 'Anda berada di luar area kantor.'
]);
