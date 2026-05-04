# Solução de Problemas — DFe Converter

---

## `java: not found` — serviço não inicia

**Sintoma:**

```
/bin/sh: 1: exec: java: not found
systemd: dfe-converter-qa.service: Main process exited, code=exited, status=127
```

**Causa:** Java não está instalado ou não está no `PATH` do ambiente systemd.

**Solução:**

```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y default-jre-headless

# RHEL/CentOS 8+
sudo dnf install -y java-17-openjdk-headless

# Verificar instalação
java -version

# Reiniciar o serviço após instalar
sudo systemctl restart dfe-converter-qa
```

> O systemd não herda o `PATH` do usuário. Se o Java estiver em um diretório não padrão,
> edite a unit file em `/etc/systemd/system/dfe-converter-qa.service` e adicione:
> ```
> Environment=JAVA_CMD=/caminho/para/java
> ```
> Após editar: `sudo systemctl daemon-reload && sudo systemctl restart dfe-converter-qa`

---

## Serviço fica em `activating (auto-restart)` em loop

**Causa:** O serviço inicia e falha repetidamente (exit-code diferente de 0).

**Diagnóstico:**

```bash
# Ver últimas linhas do journal
sudo journalctl -u dfe-converter-qa -n 50 --no-pager

# Ver status detalhado
sudo systemctl status dfe-converter-qa
```

**Causas comuns:**
- Java não encontrado (ver seção acima)
- `config.properties` com campos inválidos ou ausentes (ex.: `sync.tenant` vazio)
- Porta `sync.port` já em uso por outro processo

**Verificar porta em uso:**

```bash
sudo ss -tlnp | grep 9393
```

---

## `ERRO: Arquivo de estado não encontrado`

**Sintoma ao executar opção 7 (atualizar):**

```
ERRO: Arquivo de estado não encontrado. Use --state-file ou --install-dir.
```

**Causa:** O diretório informado não contém o arquivo `.dfe-setup.env`, indicando que não foi instalado via `dfe-setup`.

**Solução:** Use a opção **1) Instalar service** para fazer uma instalação completa. O arquivo `.dfe-setup.env` é criado automaticamente pelo instalador.

---

## Permissão negada ao executar o setup

**Sintoma:**

```
Este script precisa ser executado como root (sudo).
```

**Solução:**

```bash
# Sempre execute com sudo
sudo bash <(curl -sSL https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup)
```

---

## Falha ao baixar scripts (`curl: (60) SSL certificate`)

**Causa:** Certificado SSL não reconhecido pelo servidor (comum em ambientes corporativos com proxy SSL inspection).

**Solução temporária** (apenas em redes internas confiáveis):

```bash
sudo bash <(curl -sSLk https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup)
```

**Solução definitiva:** instale o certificado raiz da sua empresa no sistema:

```bash
# Debian/Ubuntu
sudo cp certificado-empresa.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

---

## Windows: "execution policy" ou acesso negado

**Sintoma:**

```
File ... cannot be loaded because running scripts is disabled on this system.
```

**Solução:**

```powershell
# Execute PowerShell como Administrador e use -ExecutionPolicy Bypass
powershell -ExecutionPolicy Bypass -Command "iex (iwr -useb https://prod.trackercenter.com.br/app/api/v1/dfe-converter/versoes/setup).Content"
```

---

## Windows: `nssm` não encontrado ou download falhou

**Causa:** Sem acesso à internet para baixar o `nssm` automaticamente.

**Solução:** Baixe o `nssm` manualmente em https://nssm.cc/download e coloque o executável em `C:\Program Files\DFE_Converter_PROD\nssm.exe` antes de executar o instalador.

---

## Serviço instalado mas não processa arquivos

**Verificações:**

1. O serviço está ativo?
   ```bash
   sudo systemctl status dfe-converter-prod
   ```

2. As pastas de entrada existem e têm permissão de leitura?
   ```bash
   ls -la /var/dfe/nfe/entrada
   # O usuário do serviço precisa ter acesso de leitura
   ```

3. O `sync.tenant` está correto no `config.properties`?
   ```bash
   grep sync.tenant /opt/DFE_CONVERTER_PROD/config.properties
   ```

4. O DFe Converter consegue alcançar a URL do proxy configurada?
   ```bash
   curl -I https://ws.h.dfe.mastersaf.com.br
   ```
