[Unit]
Description=CS Flags #%I
After=network.target

[Service]
Type=simple
User=cs
LimitNOFILE=10000
WorkingDirectory=/home/cs/app/
Environment=MOJO_MODE=production
Environment=LANG=en_US.UTF-8
ExecStart=/usr/bin/perl script/cs flags --id %I
Restart=always
RestartSec=15s

[Install]
WantedBy=multi-user.target
