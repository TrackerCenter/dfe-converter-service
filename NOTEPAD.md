# DF-e Conveter Service's

### Anotações para linux
```txt

// Cria Usuario
sudo useradd --system --no-create-home --shell /sbin/nologin dfeconv
// Cria Pasta
sudo mkdir -p /opt/DFE_CONVERTER_QA
// Faz
sudo cp /caminho/atual/DFe-Converter-QA.jar /opt/DFE_CONVERTER_QA/
sudo cp /caminho/atual/config.properties /opt/DFE_CONVERTER_QA/
sudo chown -R dfeconv:dfeconv /opt/DFE_CONVERTER_QA



sudo journalctl -u dfe-converter-qa -f
sudo java -Dapp.headless=true -jar /DFE_CONVERTER_QA/DFe-Converter-QA.jar --sync.config.file=config.properties
systemctl start dfe-converter-qa
systemctl status dfe-converter-qa
systemctl stop dfe-converter-qa

[Unit]
Description=DFe Converter QA
After=network.target

[Service]
Type=simple
User=dfeconv
Group=dfeconv
WorkingDirectory=/DFE_CONVERTER_QA
ExecStart=java -Dapp.headless=true -jar /DFE_CONVERTER_QA/DFe-Converter-QA.jar --sync.config.file=/DFE_CONVERTER_QA/config.properties
Restart=on-failure
RestartSec=10
Environment=JAVA_HOME=/usr/lib/jvm/jre
# Opcional: aumentar limites se necessário
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```
