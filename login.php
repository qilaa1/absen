<?php
session_start();

include 'app/auth/auth.php';
date_default_timezone_set('Asia/Jakarta');

// Cek jika tidak ada user
$sql_check_users = "SELECT COUNT(*) FROM users";
$stmt_check_users = $pdo->prepare($sql_check_users);
$stmt_check_users->execute();
$user_count = $stmt_check_users->fetchColumn();

if ($user_count == 0) {
    $_SESSION['setup'] = true;
    header('Location: start.php');
    exit;
}

$username = "";
$password = "";
$error_message = "";
$show_error = false;

// Fungsi deteksi browser & OS
function getBrowser() {
    $userAgent = $_SERVER['HTTP_USER_AGENT'];
    $browser = "Unknown Browser";
    $os = "Unknown OS";

    if (preg_match('/MSIE/i', $userAgent) || preg_match('/Trident/i', $userAgent)) {
        $browser = 'Internet Explorer';
    } elseif (preg_match('/Firefox/i', $userAgent)) {
        $browser = 'Mozilla Firefox';
    } elseif (preg_match('/Chrome/i', $userAgent)) {
        $browser = 'Google Chrome';
    } elseif (preg_match('/Safari/i', $userAgent) && !preg_match('/Chrome/i', $userAgent)) {
        $browser = 'Apple Safari';
    } elseif (preg_match('/Opera/i', $userAgent) || preg_match('/OPR/i', $userAgent)) {
        $browser = 'Opera';
    } elseif (preg_match('/Edge/i', $userAgent)) {
        $browser = 'Microsoft Edge';
    }

    if (preg_match('/win/i', $userAgent)) {
        $os = 'Windows';
    } elseif (preg_match('/macintosh|mac os x/i', $userAgent)) {
        $os = 'Mac OS';
    } elseif (preg_match('/linux/i', $userAgent)) {
        if (preg_match('/android/i', $userAgent)) {
            $os = 'Android';
        } else {
            $os = 'Linux';
        }
    } elseif (preg_match('/iphone os/i', $userAgent)) {
        $os = 'iOS (iPhone)';
    } elseif (preg_match('/ipad/i', $userAgent)) {
        $os = 'iPadOS';
    } elseif (preg_match('/ipod/i', $userAgent)) {
        $os = 'iOS (iPod)';
    } elseif (preg_match('/windows phone/i', $userAgent)) {
        $os = 'Windows Phone';
    }

    return "$browser | $os";
}

function getDeviceFingerprint() {
    $fingerprint = [];
    $userAgent = $_SERVER['HTTP_USER_AGENT'];

    if (preg_match('/\((.*?)\)/', $userAgent, $matches)) {
        $fingerprint['platform'] = $matches[1];
    }

    $fingerprint['screen'] = '<script>document.write(screen.width+"x"+screen.height+"x"+screen.colorDepth);</script>';
    $fingerprint['timezone'] = date_default_timezone_get();

    if (isset($_SERVER['HTTP_ACCEPT_LANGUAGE'])) {
        $fingerprint['languages'] = $_SERVER['HTTP_ACCEPT_LANGUAGE'];
    }

    $headers = ['HTTP_ACCEPT', 'HTTP_ACCEPT_ENCODING', 'HTTP_ACCEPT_CHARSET'];
    foreach ($headers as $header) {
        if (isset($_SERVER[$header])) {
            $fingerprint[$header] = $_SERVER[$header];
        }
    }

    $fingerprint['is_mobile'] = preg_match('/(android|bb\d+|meego).+mobile|avantgo|bada\/|blackberry|blazer|compal|...|ip(hone|od)/i', $userAgent) ? 'true' : 'false';
    $deviceString = implode('|', array_filter($fingerprint));
    $deviceHash = hash('sha256', $deviceString);

    return [
        'hash' => $deviceHash,
        'details' => json_encode($fingerprint)
    ];
}

function hasRegisteredDevice($pdo, $user_id) {
    $sql = "SELECT COUNT(*) FROM log_akses WHERE user_id = :user_id AND device_hash IS NOT NULL";
    $stmt = $pdo->prepare($sql);
    $stmt->bindParam(':user_id', $user_id, PDO::PARAM_INT);
    $stmt->execute();
    return $stmt->fetchColumn() > 0;
}

function isMatchingDevice($pdo, $user_id, $device_hash) {
    $sql = "SELECT device_hash FROM log_akses 
            WHERE user_id = :user_id 
            AND device_hash IS NOT NULL 
            ORDER BY waktu ASC LIMIT 1";

    $stmt = $pdo->prepare($sql);
    $stmt->bindParam(':user_id', $user_id, PDO::PARAM_INT);
    $stmt->execute();
    $registeredHash = $stmt->fetchColumn();
    return $device_hash === $registeredHash;
}

// Tambahkan fungsi generate QR code
function insertQRCode($pdo, $pegawai_id) {
    $kode = substr(str_shuffle('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'), 0, 6);
    $sql = "INSERT INTO qr_code (pegawai_id, kode_unik, created_at, is_used) VALUES (:pegawai_id, :kode_unik, NOW(), 0)";
    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':pegawai_id' => $pegawai_id,
        ':kode_unik' => $kode
    ]);
    return $kode;
}

// Handle login success
function loginUser($pdo, $user, $device_info, $status) {
    $_SESSION['loggedin'] = true;
    $_SESSION['username'] = $user['username'];
    $_SESSION['role'] = $user['role'];
    $_SESSION['id'] = $user['id'];

    $random_id = random_int(100000, 999999);
    $device_info_legacy = getBrowser();

    $sql_log = "INSERT INTO log_akses (id, user_id, waktu, ip_address, device_info, device_hash, device_details, status) 
                VALUES (:random_id, :user_id, NOW(), :ip_address, :device_info, :device_hash, :device_details, :status)";
    $stmt_log = $pdo->prepare($sql_log);
    $stmt_log->execute([
        ':random_id' => $random_id,
        ':user_id' => $user['id'],
        ':ip_address' => $_SERVER['REMOTE_ADDR'],
        ':device_info' => $device_info_legacy,
        ':device_hash' => $device_info['hash'],
        ':device_details' => $device_info['details'],
        ':status' => $status
    ]);

    if ($user['role'] === 'staff') {
        insertQRCode($pdo, $user['id']);
    }

    header('Location: ' . ($user['role'] == 'owner' ? 'app/pages/owner/dashboard.php' : 'app/pages/staff/attendance.php'));
    exit;
}

if ($_SERVER["REQUEST_METHOD"] == "POST" && isset($_POST['login'])) {
    $username = trim($_POST["username"]);
    $password = trim($_POST["password"]);
    $device_info = getDeviceFingerprint();

    if (empty($username)) {
        $error_message = "Mohon masukkan username.";
        $show_error = true;
    } elseif (empty($password)) {
        $error_message = "Mohon masukkan password.";
        $show_error = true;
    } else {
        $sql = "SELECT id, username, password, role FROM users WHERE username = :username";

        try {
            $stmt = $pdo->prepare($sql);
            $stmt->bindParam(":username", $username, PDO::PARAM_STR);
            $stmt->execute();

            if ($stmt->rowCount() == 1) {
                $row = $stmt->fetch(PDO::FETCH_ASSOC);

                if (password_verify($password, $row['password'])) {
                    if (hasRegisteredDevice($pdo, $row['id'])) {
                        if (!isMatchingDevice($pdo, $row['id'], $device_info['hash'])) {
                            $error_message = "Perangkat tidak dikenal. Mohon gunakan perangkat yang sudah terdaftar atau hubungi owner.";
                            $show_error = true;
                        } else {
                            loginUser($pdo, $row, $device_info, 'login');
                        }
                    } else {
                        loginUser($pdo, $row, $device_info, 'first_registration');
                    }
                } else {
                    $error_message = "Username atau password salah.";
                    $show_error = true;
                }
            } else {
                $error_message = "Username atau password salah.";
                $show_error = true;
            }
        } catch (PDOException $e) {
            $error_message = "Terjadi kesalahan sistem. Silakan coba lagi.";
            $show_error = true;
        }
    }
}
unset($pdo);
?>


<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Si Hadir - Login</title>
    <link rel="icon" type="image/x-icon" href="assets/icon/favicon.ico" />
    <link href="https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700&display=swap"
        rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        :root {
            --primary: #2563eb;
            --primary-light: #60a5fa;
            --text-primary: #1e293b;
            --text-secondary: #64748b;
            --background: #ffffff;
            --card-bg: rgba(255, 255, 255, 0.7);
            --hover-bg: rgba(255, 255, 255, 0.9);
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: 'Poppins', sans-serif;
        }

        body {
            min-height: 100vh;
            background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%);
            color: var(--text-primary);
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 2rem;
        }

        .container {
            width: 100%;
            max-width: 480px;
            background: var(--card-bg);
            backdrop-filter: blur(10px);
            border-radius: 24px;
            border: 1px solid rgba(255, 255, 255, 0.5);
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.05);
            padding: 3rem;
        }

        .header {
            text-align: center;
            margin-bottom: 2rem;
        }

        .title {
            font-size: 2rem;
            font-weight: 700;
            color: var(--text-primary);
            margin-bottom: 1rem;
        }

        .subtitle {
            font-size: 1rem;
            color: var(--text-secondary);
            max-width: 400px;
            margin: 0 auto;
            line-height: 1.6;
        }

        .form {
            display: flex;
            flex-direction: column;
            gap: 1.5rem;
        }

        .form-group {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
        }

        /* Add this to the existing style section */
        .forgot-password {
            text-align: left;
            margin-top: -0.5rem;
        }

        .forgot-password a {
            color: var(--primary);
            text-decoration: none;
            font-size: 0.9rem;
            transition: color 0.3s ease;
        }

        .forgot-password a:hover {
            color: var(--primary-light);
        }

        .label {
            font-size: 0.95rem;
            color: var(--text-secondary);
            font-weight: 500;
        }

        .input {
            padding: 1rem 1.25rem;
            border-radius: 12px;
            border: 1px solid rgba(0, 0, 0, 0.1);
            background: var(--background);
            font-size: 1rem;
            color: var(--text-primary);
            outline: none;
            transition: all 0.3s ease;
        }

        .input:focus {
            border-color: var(--primary);
        }

        .remember-wrapper {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            margin-top: -0.5rem;
        }

        .remember-checkbox {
            width: 1.2rem;
            height: 1.2rem;
            accent-color: var(--primary);
        }

        .remember-label {
            font-size: 0.95rem;
            color: var(--text-secondary);
        }

        .btn {
            margin-top: 1.5rem;
            padding: 1rem 2rem;
            border-radius: 12px;
            padding: 1rem 2rem;
            border-radius: 12px;
            font-weight: 500;
            font-size: 1rem;
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 0.5rem;
            transition: all 0.3s ease;
            background: var(--primary);
            color: white;
            border: none;
            cursor: pointer;
            width: 100%;
        }

        .btn:hover {
            background: var(--primary-light);
        }

        .btn:disabled {
            opacity: 0.7;
            cursor: not-allowed;
        }

        .alert {
            padding: 1rem;
            border-radius: 12px;
            margin-bottom: 1.5rem;
            background-color: #fee2e2;
            color: #991b1b;
            border: 1px solid #fecaca;
            display:
                <?php echo !empty($error_message) ? 'block' : 'none'; ?>
            ;
        }

        @media (max-width: 480px) {
            .container {
                padding: 2rem;
            }

            .title {
                font-size: 1.75rem;
            }

            .subtitle {
                font-size: 0.9rem;
            }
        }
    </style>
</head>

<body>
    <div class="container">
        <header class="header">
            <h1 class="title">Si Hadir</h1>
            <p class="subtitle">
                Silakan masuk menggunakan akun Anda untuk melanjutkan
            </p>
        </header>

        <?php if (!empty($error_message)): ?>
            <div class="alert" id="error-alert">
                <?php echo htmlspecialchars($error_message); ?>
            </div>
            <script>
                // Automatically hide the error message after 5 seconds
                var errorAlert = document.getElementById('error-alert');
                if (errorAlert) {
                    setTimeout(function () {
                        errorAlert.style.display = 'none';
                    }, 5000);
                }
            </script>
        <?php endif; ?>

        <form action="<?php echo htmlspecialchars($_SERVER["PHP_SELF"]); ?>" method="post" class="form">
            <div class="form-group">
                <label for="username" class="label">Username</label>
                <input type="text" id="username" name="username" class="input"
                    value="<?php echo htmlspecialchars($username); ?>" required>
            </div>
            <div class="form-group">
                <label for="password" class="label">Password</label>
                <input type="password" id="password" name="password" class="input" required>
            </div>
            <div class="forgot-password">
                <a href="app/recovery/forgotPassword.php">Lupa username atau password?</a>
            </div>
            <button type="submit" name="login" value="1" class="btn">
                <i class="fas fa-sign-in-alt"></i>
                <span>Masuk</span>
            </button>
        </form>
    </div>
</body>

</html>