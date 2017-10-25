[Unit]
Description=Register with MaaS Region Controller
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
PassEnvironment=MAAS_ENDPOINT MAAS_REGION_SECRET
ExecStart=/usr/local/bin/register-rack-controller.sh

[Install]
WantedBy=multi-user.target
