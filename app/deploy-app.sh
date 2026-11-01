#!/usr/bin/env bash
# Implantação da aplicação didática "delivery-config" (Amazon Linux 2023).
#
# Executado pelo AWS Systems Manager (Run Command ou associação do State Manager).
# É IDEMPOTENTE: pode rodar várias vezes; só reinicia o serviço se algo mudou.
#
# A aplicação (Python, só biblioteca padrão) escuta na porta 8080 e mostra:
#   - identidade da instância (hostname, ID e zona de disponibilidade);
#   - configuração lida do Parameter Store em /delivery/dev/ (via IAM Role);
#   - se a senha foi carregada (a senha NUNCA é exibida, só o tamanho).
# Nenhuma credencial fica no código: a leitura usa o instance profile da EC2.
set -euo pipefail

APP_DIR="/opt/delivery-config"
APP_USER="deliveryapp"
SERVICO="delivery-config"
PORTA="8080"
CAMINHO="/delivery/dev/"
MUDOU=0

# Região descoberta pelo IMDSv2 (nada fixo no script)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGIAO=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

# Grava o arquivo (conteúdo no stdin) somente se for diferente do atual
gravar_se_mudou() {
  local destino="$1" tmp
  tmp=$(mktemp)
  cat > "${tmp}"
  if ! cmp -s "${tmp}" "${destino}" 2>/dev/null; then
    install -m 0644 "${tmp}" "${destino}"
    MUDOU=1
  fi
  rm -f "${tmp}"
}

# 1. Usuário de sistema sem login e diretório da aplicação
id "${APP_USER}" >/dev/null 2>&1 || useradd --system --shell /sbin/nologin "${APP_USER}"
mkdir -p "${APP_DIR}"

# 2. Código da aplicação
gravar_se_mudou "${APP_DIR}/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""Aplicação didática: identidade da instância + Parameter Store."""
import html
import json
import os
import socket
import subprocess
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CAMINHO = os.environ.get("PARAM_PATH", "/delivery/dev/")
PORTA = int(os.environ.get("PORT", "8080"))
CACHE_SEGUNDOS = 30
_cache = {"em": 0.0, "dados": {}}


def imds(caminho):
    """Lê um metadado da instância usando IMDSv2."""
    base = "http://169.254.169.254/latest/"
    req = urllib.request.Request(
        base + "api/token", method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
    token = urllib.request.urlopen(req, timeout=2).read().decode()
    req = urllib.request.Request(
        base + "meta-data/" + caminho,
        headers={"X-aws-ec2-metadata-token": token})
    return urllib.request.urlopen(req, timeout=2).read().decode()


def ler_parametros():
    """Lê /delivery/dev/ (recursivo, com descriptografia) e guarda 30 s em cache."""
    agora = time.time()
    if agora - _cache["em"] < CACHE_SEGUNDOS:
        return _cache["dados"]
    saida = subprocess.run(
        ["aws", "ssm", "get-parameters-by-path", "--path", CAMINHO,
         "--recursive", "--with-decryption", "--output", "json"],
        capture_output=True, text=True, timeout=20, check=True).stdout
    dados = {p["Name"]: p["Value"] for p in json.loads(saida)["Parameters"]}
    _cache.update(em=agora, dados=dados)
    return dados


def montar():
    """Monta o dicionário exibido pela aplicação (sem expor a senha)."""
    erro = None
    try:
        params = ler_parametros()
    except subprocess.CalledProcessError as e:
        params, erro = {}, (e.stderr or "erro ao chamar a AWS CLI").strip()[-300:]
    except Exception as e:  # noqa: BLE001 - exibir o motivo no laboratório
        params, erro = {}, str(e)[:300]
    senha = params.get(CAMINHO + "database/senha")
    try:
        instancia, zona = imds("instance-id"), imds("placement/availability-zone")
    except Exception:  # noqa: BLE001
        instancia, zona = "indisponivel", "indisponivel"
    return {
        "hostname": socket.gethostname(),
        "instancia": instancia,
        "zona": zona,
        "ambiente": params.get(CAMINHO + "ambiente"),
        "database_host": params.get(CAMINHO + "database/host"),
        "database_usuario": params.get(CAMINHO + "database/usuario"),
        "notificacoes": params.get(CAMINHO + "notificacoes"),
        "senha_carregada": senha is not None,
        "senha_tamanho": len(senha) if senha else 0,
        "erro_parameter_store": erro,
    }


def pagina(dados):
    linhas = "".join(
        f"<tr><th scope='row'>{html.escape(k)}</th>"
        f"<td>{html.escape(str(v))}</td></tr>" for k, v in dados.items())
    return (
        "<!doctype html><html lang='pt-BR'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<title>delivery-config</title></head><body>"
        "<h1>delivery-config</h1>"
        f"<table border='1' cellpadding='6'>{linhas}</table>"
        "<p>Configuração lida do Parameter Store. A senha nunca é exibida.</p>"
        "</body></html>")


class Handler(BaseHTTPRequestHandler):
    def _enviar(self, codigo, tipo, corpo):
        dados = corpo.encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo + "; charset=utf-8")
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def do_GET(self):
        if self.path == "/saude":
            self._enviar(200, "application/json", json.dumps({"status": "ok"}))
        elif self.path == "/config":
            self._enviar(200, "application/json",
                         json.dumps(montar(), ensure_ascii=False))
        elif self.path == "/":
            self._enviar(200, "text/html", pagina(montar()))
        else:
            self._enviar(404, "application/json", json.dumps({"erro": "nao encontrado"}))


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORTA), Handler).serve_forever()
PYEOF

# 3. Serviço systemd (usuário sem privilégios, reinício automático)
gravar_se_mudou "/etc/systemd/system/${SERVICO}.service" <<EOF
[Unit]
Description=Aplicacao didatica delivery-config
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
Environment=AWS_DEFAULT_REGION=${REGIAO}
Environment=PORT=${PORTA}
Environment=HOME=/tmp
ExecStart=/usr/bin/python3 ${APP_DIR}/app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 4. Ativar o serviço; reiniciar só se arquivo mudou
systemctl daemon-reload
systemctl enable --now "${SERVICO}.service"
if [ "${MUDOU}" = "1" ]; then
  systemctl restart "${SERVICO}.service"
fi

# 5. Verificação de saúde (falha o comando se a aplicação não responder)
for _ in $(seq 1 15); do
  if curl -fs --max-time 2 "http://127.0.0.1:${PORTA}/saude" >/dev/null; then
    echo "OK: ${SERVICO} em execucao na porta ${PORTA} (regiao ${REGIAO}, alterado=${MUDOU})"
    exit 0
  fi
  sleep 1
done
echo "ERRO: ${SERVICO} nao respondeu em /saude" >&2
systemctl status "${SERVICO}.service" --no-pager || true
exit 1
