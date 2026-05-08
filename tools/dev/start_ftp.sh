# Start pyftpdlib on the host as the test FTP server for FTP.EXE.
#
# Default: anonymous read-only login (-w grants write).  The Sprinter
# FTP.EXE without -u/-p connects as anonymous / anonymous@.
#
# To test non-anonymous authentication, replace this command with one
# of the variants below (pyftpdlib disables anonymous as soon as -u is
# supplied):
#
#   sudo python3 -m pyftpdlib -p 21 -i 192.168.7.1 -d /tmp/wget-test -w \
#       -u alice -P secret
#
# Then on the Sprinter side:
#
#   FTP 192.168.7.1 file.bin -u alice -p secret
#
# A bad username or password produces "530 Authentication failed." and
# FTP.EXE exits with RESULT FAIL.  An -u alone (no -p on the host)
# accepts any password, including the empty one FTP.EXE sends when the
# user gives -u without -p.

sudo python3 -m pyftpdlib -p 21 -i 192.168.7.1 -d /tmp/wget-test -w
