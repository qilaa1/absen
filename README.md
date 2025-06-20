# Instalasi

### 1. Clone Repositori
Clone repositori ini ke dalam server atau komputer lokal dengan perintah berikut:
```bash
git clone https://github.com/username/absen.git
```

### 2. Konfigurasi File `auth.php`
File konfigurasi untuk autentikasi ada di `app/auth/auth.php`. Sesuaikan pengaturan database di dalam file ini, seperti username, password, dan host database Anda.

### 3. Konfigurasi Email
Ubah pengaturan email pada dua file berikut:
- `app/handler/email_recovery_handler.php`
- `app/api/api_send_otp.php`

Ganti bagian berikut dengan informasi akun Gmail dan Application Key:
```php
$mail->Username = '*****'; // email username
$mail->Password = '*****'; // application password
```

**Catatan:** Pastikan menggunakan **App Password** dari akun Gmail. Gmail akan menolak login langsung menggunakan password biasa untuk aplikasi pihak ketiga.

### 4. Import File SQL ke Database MySQL
File database `.sql` tersedia di `database/absensi.sql`. Import file ini ke dalam database MySQL. Nama database harus sesuai dengan nama file, dan pastikan menggunakan DBMS terbaru (MariaDB/MySQL versi 10.11 ke atas) serta PHP >= 8.1.


### 5. Jalankan Aplikasi di Server Lokal
Jika menjalankan aplikasi di server lokal, pastikan untuk mengaktifkan **Event Scheduler** di MariaDB/MySQL untuk menjalankan tugas terjadwal. Event scheduler dapat diaktifkan dengan perintah berikut:
```sql
SET GLOBAL event_scheduler = ON;
```

Jika menggunakan hosting atau remote server yang tidak dizinkan akses root, maka perlu menggunakan **cron job** untuk menjalankan event secara terjadwal. Tambahkan entri berikut pada file crontab untuk menjalankan perintah setiap 1 menit atau lebih cepat:
```bash
* * * * * /usr/bin/php /path/to/your/sihadir/web/sihadir/command.php
```

**Catatan:** Untuk server lokal, pastikan event scheduler diaktifkan agar aplikasi dapat memproses tugas terjadwal. Jika menggunakan hosting, gunakan cron job untuk menangani proses secara otomatis.

---