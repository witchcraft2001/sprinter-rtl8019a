#!/bin/sh                                                                
mkdir -p /tmp/wget-test                                                                                                       
# скопируй туда любые файлы для проверки, например:          
cp /Users/dmitry/dev/zx/sprinter/other/07BA-90CE/BIN/FFORMAT.TXT /tmp/wget-test/                                              
# несколько разных размеров:                                                     
dd if=/dev/urandom of=/tmp/wget-test/2k.bin bs=1024 count=2                                                                   
dd if=/dev/urandom of=/tmp/wget-test/24k.bin bs=1024 count=24                      
dd if=/dev/urandom of=/tmp/wget-test/56k.bin bs=1024 count=56                                                                 
cd /tmp/wget-test                                                                                                             
sudo python3 -m http.server 80 --bind 192.168.7.1 