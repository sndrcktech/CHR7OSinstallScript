#!/bin/bash

set -e

# Устанавливаем необходимые пакеты
sudo apt update && sudo apt install -y kpartx util-linux coreutils wget unzip

# Определяем интерфейс с default route
INTERFACE=$(ip route | grep default | awk '{print $5}')

# Получаем IP/CIDR
CIDR_FULL=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}')
IPADDR=$(echo $CIDR_FULL | cut -d/ -f1)
CIDR=$(echo $CIDR_FULL | cut -d/ -f2)

# Вычисляем network вручную
IFS=. read -r i1 i2 i3 i4 <<< "$IPADDR"
MASKBITS=$CIDR

MASK=$(( 0xFFFFFFFF << (32 - MASKBITS) & 0xFFFFFFFF ))
m1=$(( (MASK >> 24) & 0xFF ))
m2=$(( (MASK >> 16) & 0xFF ))
m3=$(( (MASK >> 8) & 0xFF ))
m4=$(( MASK & 0xFF ))

IPDEC=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
NETDEC=$(( IPDEC & MASK ))

n1=$(( (NETDEC >> 24) & 0xFF ))
n2=$(( (NETDEC >> 16) & 0xFF ))
n3=$(( (NETDEC >> 8) & 0xFF ))
n4=$(( NETDEC & 0xFF ))

NETWORK="$n1.$n2.$n3.$n4"

# Определяем Gateway
GATEWAY=$(ip route | grep default | awk '{print $3}')

# Определяем диск (vda/sda)
if [ -b /dev/vda ]; then
    DISK="/dev/vda"
elif [ -b /dev/sda ]; then
    DISK="/dev/sda"
else
    echo "Disk not found (vda/sda)"
    exit 1
fi

echo "[+] Интерфейс: $INTERFACE"
echo "[+] IP адрес: $IPADDR/$CIDR"
echo "[+] Сеть: $NETWORK"
echo "[+] Gateway: $GATEWAY"
echo "[+] Диск: $DISK"

IMG_URL="https://download.mikrotik.com/routeros/7.13.2/chr-7.13.2.img.zip"
IMG_FILE="chr-7.13.2.img"
MOUNT_DIR="/mnt/chrimg"

echo "[+] Скачиваем CHR образ..."
sudo wget -O chr.img.zip "$IMG_URL"

echo "[+] Распаковываем образ..."
sudo unzip -o chr.img.zip

echo "[+] Создаём loop-устройство и маппим разделы..."
LOOPDEV=$(sudo losetup --show -f $IMG_FILE)
sudo kpartx -av $LOOPDEV

PART_DEV="/dev/mapper/$(basename $LOOPDEV)p1"

echo "[+] Монтируем раздел $PART_DEV..."
sudo mkdir -p $MOUNT_DIR
sudo mount $PART_DEV $MOUNT_DIR

echo "[+] Патчим autorun.scr..."
sudo rm -f $MOUNT_DIR/autorun.scr

#sudo cat > $MOUNT_DIR/autorun.scr <<EOF
sudo tee $MOUNT_DIR/autorun.scr > /dev/null <<EOF
# MikroTik autorun.scr auto-patched
user admin password=123456
interface ethernet set [find default-name=ether1] disabled=no
ip address add address=${IPADDR}/${CIDR} interface=ether1 network=${NETWORK}
ip route add gateway=${GATEWAY}
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
/ip neighbor discovery-settings
set discover-interface-list=none
/tool mac-server
set allowed-interface-list=none
/tool mac-server mac-winbox
set allowed-interface-list=none
/tool mac-server ping
set enabled=no
# auto-update.rsc — Автоматическое обновление RouterOS CHR
:log info "=== Автообновление RouterOS запущено ==="
/system package update check-for-updates
:if ([/system package update get status] = "New version available") do={
    :log info "Доступна новая версия RouterOS. Начинается загрузка..."
    /system package update download
    # Ждём окончания загрузки (проверяем каждые 5 секунд)
    :while ([/system package update get download-status] != "Completed") do={
        :delay 5
    }
    :log info "Загрузка завершена. Запуск установки..."
    /system package update install
    # После этой команды устройство автоматически перезагрузится
} else={
    :log info "Обновлений не найдено. Автообновление завершено."
}
EOF

echo "[+] Сохраняем и размонтируем..."
sudo sync
sudo umount $MOUNT_DIR
sudo kpartx -dv $LOOPDEV
sudo losetup -d $LOOPDEV
sudo rmdir $MOUNT_DIR

echo "[+] Переход в безопасный режим перед dd..."

#sudo echo u > /proc/sysrq-trigger
#sleep 5
echo "[+] Синхронизация дисков перед dd..."
sync
echo 3 > /proc/sys/vm/drop_caches
blockdev --flushbufs /dev/vda
echo "[+] Пишем образ на диск $DISK..."
sudo dd if=$IMG_FILE bs=4M of=$DISK oflag=sync status=progress

echo "[+] Перезагружаем сервер..."
sudo echo b > /proc/sysrq-trigger
