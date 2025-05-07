#!/bin/bash
# === INPUT MANUAL ===
read -p "Masukkan nama interface (contoh: eth0): " INTERFACE
read -p "Masukkan IP Prefix subnet (contoh: 89.144.50): " IP_PREFIX
read -p "Masukkan IP START (angka akhir, contoh: 129): " START
read -p "Masukkan IP END (angka akhir, contoh: 255): " END
read -p "Masukkan netmask (contoh: 24): " NETMASKS

PORT_START=3128
USERNAME="vodkaace"
PASSWORD="indonesia"
PASSWD_FILE="/etc/squid/passwd"
SQUID_CONF="/etc/squid/squid.conf"
HASIL_FILE="hasil.txt"

# === CEK INTERFACE ===
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "[!] Interface $INTERFACE tidak ditemukan. Periksa kembali." >&2
    exit 1
fi

# === TAMBAHKAN IP KE INTERFACE ===
echo "[+] Menambahkan IP ke interface $INTERFACE"
for i in $(seq $START $END); do
    IP="$IP_PREFIX.$i"
    if ! ip addr show dev $INTERFACE | grep -q "$IP"; then
        sudo ip addr add "$IP/$NETMASKS" dev $INTERFACE
    fi
done

# === INSTALL PAKET YANG DIBUTUHKAN ===
echo "[+] Menginstall Squid dan Apache utils"
sudo apt update
sudo apt install squid apache2-utils -y

# === SETUP AUTH USER ===
echo "[+] Menambahkan user proxy $USERNAME"
if [ ! -f "$PASSWD_FILE" ]; then
    sudo htpasswd -cb "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
else
    sudo htpasswd -b "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
fi

# === BACKUP CONFIG LAMA ===
echo "[+] Membackup konfigurasi Squid lama"
sudo cp "$SQUID_CONF" "$SQUID_CONF.bak.$(date +%s)"

# === BUAT KONFIGURASI BARU ===
echo "[+] Menulis konfigurasi baru ke $SQUID_CONF"
sudo tee "$SQUID_CONF" > /dev/null <<EOF
workers 4
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Private Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated

access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
cache_store_log none
logfile_rotate 0
buffered_logs on
dns_v4_first on

# Opsi cache (bisa dinonaktifkan jika forward proxy murni)
# cache_mem 64 MB
# maximum_object_size_in_memory 512 KB
# maximum_object_size 4 MB
# cache_dir ufs /var/spool/squid 100 16 256
EOF

for i in $(seq $START $END); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "http_port $PORT" | sudo tee -a "$SQUID_CONF" > /dev/null
    echo "acl to$i myport $PORT" | sudo tee -a "$SQUID_CONF" > /dev/null
    echo "tcp_outgoing_address $IP to$i" | sudo tee -a "$SQUID_CONF" > /dev/null
    echo "" | sudo tee -a "$SQUID_CONF" > /dev/null
done

# === BUKA FIREWALL (JIKA UFW AKTIF) ===
if command -v ufw > /dev/null && sudo ufw status | grep -q "Status: active"; then
    echo "[+] Membuka port di firewall (UFW)"
    for i in $(seq $START $END); do
        PORT=$((PORT_START + i - START))
        sudo ufw allow "$PORT/tcp" comment "Allow Squid proxy port $PORT"
    done
fi

# === SIMPAN HASIL KE FILE ===
echo "[+] Menyimpan hasil konfigurasi ke $HASIL_FILE"
: > "$HASIL_FILE"

for i in $(seq $START $END); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "$USERNAME:$PASSWORD@$IP:$PORT" >> "$HASIL_FILE"
done

# === SET SYSTEMD LIMIT UNTUK SQUID ===
sudo mkdir -p /etc/systemd/system/squid.service.d
cat <<EOF | sudo tee /etc/systemd/system/squid.service.d/override.conf
[Service]
LimitNOFILE=65535
EOF

# === SET LIMIT SYSTEM-WIDE ===
echo "[+] Menambahkan limit nofile ke sistem"
sudo tee -a /etc/security/limits.conf > /dev/null <<EOF

* soft nofile 65535
* hard nofile 65535
EOF

sudo tee /etc/systemd/user.conf > /dev/null <<EOF
DefaultLimitNOFILE=65535
EOF

sudo tee /etc/systemd/system.conf > /dev/null <<EOF
DefaultLimitNOFILE=65535
EOF

# === RESTART SQUID DENGAN ANIMASI LOADING ===
echo "[+] Restarting Squid"
echo -n "Loading"
loading_animation() {
    local pid=$1
    local delay=0.1
    local spin='|/-\'

    while ps -p $pid > /dev/null; do
        for i in $(seq 0 3); do
            echo -ne "\rLoading ${spin:$i:1}"
            sleep $delay
        done
    done
    echo -ne "\r[+] Restart Squid Done     \n"
}

(
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl restart squid
) &

loading_animation $!

# === CEK LIMIT FILE DESCRIPTOR ===
echo "Cek limit file descriptor Squid:"
cat /proc/$(pidof squid)/limits | grep "Max open files"

echo "✅ Setup selesai! Proxy siap digunakan."
echo "📄 Hasil disimpan di: $HASIL_FILE"
