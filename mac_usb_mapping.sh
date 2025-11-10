MAC="00:0f:13:28:1f:03"
IFACE=$(ip -br link | grep -i "$MAC" | awk '{print $1}')

# Get the parent directory of the device
USB_DEV=$(readlink -f /sys/class/net/$IFACE/device)/..

BUSNUM=$(cat "$USB_DEV/busnum")
DEVNUM=$(cat "$USB_DEV/devnum")
VENDOR=$(cat "$USB_DEV/idVendor")
PRODUCT=$(cat "$USB_DEV/idProduct")
MANUFACTURER=$(cat "$USB_DEV/manufacturer")
PRODUCT_STR=$(cat "$USB_DEV/product")

printf "Bus %03d Device %03d: ID %s:%s %s %s\n" "$BUSNUM" "$DEVNUM" "$VENDOR" "$PRODUCT" "$MANUFACTURER" "$PRODUCT_STR"