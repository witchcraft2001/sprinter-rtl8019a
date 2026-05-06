sudo dnsmasq -k --interface=feth1 --bind-interfaces \
    --dhcp-range=192.168.7.100,192.168.7.150,12h \
    --dhcp-option=3,192.168.7.1 \
    --dhcp-option=6,192.168.7.1 \
    --server=1.1.1.1 --server=8.8.8.8 --no-resolv