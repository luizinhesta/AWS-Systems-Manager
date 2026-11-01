# Implantação — AWS Systems Manager e Parameter Store: acesso sem SSH, automação e segredo

> Passo a passo em português do Brasil, com o caminho exato no Console, o que preencher, o resultado esperado e os erros mais comuns de cada etapa.
>
> Execução 100% manual pelo Console AWS. Região: **`us-east-1` (Leste dos EUA — N. Virgínia)**. Os scripts curtos são de leitura/validação. O código da aplicação (Parte 4) fica no arquivo `app/deploy-app.sh`.

![Diagrama da arquitetura: Systems Manager, duas EC2 em zonas diferentes, Parameter Store, KMS e função IAM](imagens/imagem%20(35).png)

## Antes de começar

- [ ] Conta AWS com permissão para usar **EC2, VPC, IAM, Systems Manager e KMS**.
- [ ] Console em português: no canto inferior esquerdo (ou em **Configurações** da conta), escolha o idioma **Português (Brasil)**.
- [ ] Região **N. Virgínia (us-east-1)** selecionada no seletor, no canto superior direito. **Use a mesma região o laboratório inteiro**; se trocar de região, os recursos "somem" da tela.
- [ ] Ciência dos custos: **2 EC2** (`t3.micro`), 2 volumes EBS, 2 IPv4 públicos e **1 chave KMS (USD 1.00/mês)**. Execute a **Limpeza** no final.
- [ ] Nenhum recurso prévio é necessário: o laboratório cria tudo.

> **Nomes de menus:** os nomes dos serviços e menus aparecem como no Console em português. Quando o nome em inglês é o mais usado, ele vem entre parênteses. Pequenas diferenças de texto podem existir conforme a atualização do Console.

### Custos estimados (us-east-1)

Valores **aproximados**, sem considerar Free Tier. Confirme na página de preços da AWS antes de começar.

| Recurso | Custo aproximado | Observação |
|---------|------------------|------------|
| 2 × EC2 `t3.micro` | USD 0.0104/hora cada (≈ USD 0.02/hora as duas) | Cobradas enquanto estiverem em execução |
| 2 × volume EBS `gp3` de 8 GiB | ≈ USD 0.64/mês cada | Cobrado até o volume ser excluído, **mesmo com a instância parada** |
| 2 × IPv4 público | USD 0.005/hora cada | Cessa ao encerrar a instância |
| Chave KMS (CMK) | **USD 1.00/mês** | Cobrada até a exclusão agendada (janela de 7 a 30 dias) |
| Session Manager, Run Command, State Manager, Automation | USD 0.00 | Sem custo adicional do serviço |
| Parameter Store (camada Padrão) | USD 0.00 por parâmetro | A camada Avançada (USD 0.05/parâmetro/mês) não é usada |
| VPC padrão, security group, função IAM | USD 0.00 | |

Para uma execução de poucas horas o custo é baixo; o que mais pesa é esquecer as EC2 ligadas e a chave KMS ativa. Faça a **Limpeza** no final.

### Valores que você vai substituir

| Placeholder | O que é | Onde encontrar |
|-------------|---------|----------------|
| `<REGIAO_AWS>` | Região do laboratório | Use `us-east-1` |
| `<ID_CONTA>` | ID da conta (12 dígitos) | Canto superior direito, clique no seu nome/conta → **ID da conta** |
| `<ID_DA_CMK>` | ID da chave KMS | **KMS → Chaves gerenciadas pelo cliente → sua chave → ID da chave** (criada no passo 3.9) |
| `<NOME_DO_IAM_ROLE>` | Nome da função IAM | `role-ssm-demo-ec2` |
| `<HOST_FICTICIO>` | Host de banco de exemplo | `db.exemplo.interno` |
| `<USUARIO_FICTICIO>` | Usuário de exemplo | `app_delivery` |
| `<SENHA_FICTICIA>` | Senha de exemplo | `SenhaDeExemplo#2024` |
| `<IPV4_PUBLICO>` | IPv4 público da EC2 | **EC2 → Instâncias → a instância → Endereço IPv4 público** |

> **Nunca use credenciais reais.** Todos os valores acima são fictícios.

### Nomes usados no laboratório

| Item | Nome/valor |
|------|------------|
| Security group | `sg-ssm-demo` (sem regras de entrada) |
| Função IAM | `role-ssm-demo-ec2` (+ `AmazonSSMManagedInstanceCore`) |
| EC2 (2 instâncias) | `ec2-ssm-demo-1` e `ec2-ssm-demo-2` (Amazon Linux 2023, `t3.micro`, sem par de chaves, tag `Ambiente=ssm-demo`) |
| Chave KMS (alias) | `alias/delivery-dev-securestring` |
| Parâmetro `String` | `/delivery/dev/ambiente` = `desenvolvimento` |
| Parâmetro `String` | `/delivery/dev/database/host` = `<HOST_FICTICIO>` |
| Parâmetro `String` | `/delivery/dev/database/usuario` = `<USUARIO_FICTICIO>` |
| Parâmetro `StringList` | `/delivery/dev/notificacoes` = `email1,email2` |
| Parâmetro `SecureString` | `/delivery/dev/database/senha` = `<SENHA_FICTICIA>` |
| Associação do State Manager | `ssm-demo-implanta-app` |

### Anote durante o laboratório

| O que anotar | Valor |
|--------------|-------|
| ID da `ec2-ssm-demo-1` | |
| ID da `ec2-ssm-demo-2` | |
| IPv4 público de cada instância | |
| `<ID_CONTA>` | |
| `<ID_DA_CMK>` e ARN da chave | |

> Este laboratório é **autônomo**: a Parte 0 cria toda a infraestrutura de apoio.

---

## Parte 0 — Preparação do ambiente (rede, função IAM e 2 EC2)

### Passo 0.1 — Verificar a VPC padrão
- **Onde:** Console → **VPC** → menu lateral **Suas VPCs**.
- **O que fazer:** procure uma VPC com a coluna **VPC padrão = Sim**. Se não existir, clique em **Ações → Criar VPC padrão → Criar VPC padrão**.
- **Resultado esperado:** existe uma VPC padrão (normalmente `172.31.0.0/16`).
- **Por que importa:** ela já tem Internet Gateway e sub-redes públicas, o que dá a saída para a internet que o SSM Agent precisa.

![VPC padrão da região, com CIDR 172.31.0.0/16 e sub-redes públicas](imagens/imagem%20(27).png)

### Passo 0.2 — Criar o security group `sg-ssm-demo` sem regras de entrada
- **Onde:** **EC2** → **Rede e segurança → Grupos de segurança** → **Criar grupo de segurança**.
- **O que fazer:**
  1. **Nome do grupo de segurança:** `sg-ssm-demo`.
  2. **Descrição:** `SG sem regras de entrada`.
  3. **VPC:** a VPC padrão.
  4. **Regras de entrada:** **não adicione nenhuma** (se houver alguma regra sugerida, remova com **Excluir**).
  5. **Regras de saída:** deixe a regra padrão (todo o tráfego).
  6. Clique em **Criar grupo de segurança**.
- **Resultado esperado:** o grupo aparece na lista e a aba **Regras de entrada** está vazia.
- **Erro comum:** deixar a regra de SSH (porta 22) sugerida pelo assistente de lançamento da EC2. Aqui o grupo é criado separado justamente para ficar sem entrada.

### Passo 0.3 — Criar a função IAM `role-ssm-demo-ec2`
- **Onde:** **IAM** → **Gerenciamento de acesso → Funções** → **Criar função**.
- **O que fazer:**
  1. **Tipo de entidade confiável:** **Serviço da AWS**.
  2. **Caso de uso:** **EC2** e clique em **Avançar**.
  3. Na busca de políticas, digite `AmazonSSMManagedInstanceCore` e **marque** a política.
  4. **Avançar**. **Nome da função:** `role-ssm-demo-ec2`.
  5. **Descrição:** `Role da EC2 (Systems Manager e Parameter Store)`.
  6. Clique em **Criar função**.
- **Resultado esperado:** a função aparece na lista; na aba **Permissões** consta `AmazonSSMManagedInstanceCore`.
- **Observação:** ao criar a função para EC2 pelo Console, o **perfil de instância** (instance profile) é criado automaticamente com o mesmo nome.

### Passo 0.4 — Lançar as 2 instâncias EC2
- **Onde:** **EC2** → **Instâncias → Instâncias** → **Executar instâncias**.
- **O que fazer:**
  1. **Nome:** `ec2-ssm-demo`.
  2. **Tags adicionais:** **Adicionar tag** → **Chave** `Ambiente`, **Valor** `ssm-demo`, **Tipos de recurso:** marque **Instâncias** e **Volumes**.
  3. **AMI:** **Amazon Linux 2023** (64 bits, x86). Ela já traz o SSM Agent e a AWS CLI.
  4. **Tipo de instância:** `t3.micro`.
  5. **Par de chaves (login):** **Prosseguir sem um par de chaves**.
  6. **Configurações de rede → Editar:** **VPC** padrão; **Atribuir IP público automaticamente:** **Habilitar**; **Firewall:** **Selecionar grupo de segurança existente** → `sg-ssm-demo`.
  7. **Armazenamento:** deixe o padrão (8 GiB `gp3`).
  8. **Detalhes avançados → Perfil de instância do IAM:** `role-ssm-demo-ec2`.
  9. No painel **Resumo**, **Número de instâncias:** `2`.
  10. Clique em **Executar instância**.
  11. Depois que subirem, clique no lápis da coluna **Nome** de cada uma e renomeie para `ec2-ssm-demo-1` e `ec2-ssm-demo-2`.
- **Resultado esperado:** duas instâncias em **Em execução**; depois de alguns minutos, **2/2 verificações aprovadas**. Anote os dois IDs.
- **Erro comum:** esquecer o **Perfil de instância do IAM**. Sem ele a instância não aparece no Systems Manager. Para corrigir: selecione a instância → **Ações → Segurança → Modificar função do IAM**, escolha `role-ssm-demo-ec2` e **reinicie** a instância.

### Passo 0.5 — Aguardar o registro no Systems Manager
- **Onde:** **Systems Manager** → **Fleet Manager** (Gerenciador de frota).
- **O que fazer:** atualize a lista até as duas instâncias aparecerem.
- **Resultado esperado:** as duas com **Status do ping = Online** (leva de 2 a 5 minutos).
- **Se não aparecer em ~10 minutos:** confira (1) a função IAM associada, (2) o IP público habilitado e (3) a saída (regra de saída do security group).

> Nas Partes 1 a 3 use a `ec2-ssm-demo-1`. A `ec2-ssm-demo-2` entra na Parte 4.

---

## Parte 1 — Session Manager (acesso sem SSH e sem porta 22)

### Passo 1.1 — Confirmar a instância em execução
- **Onde:** **EC2 → Instâncias**.
- **O que fazer:** clique na `ec2-ssm-demo-1` e confirme **Estado da instância = Em execução**. Anote o ID (`i-...`).

### Passo 1.2 — Confirmar a função IAM e a política
- **Onde:** **IAM → Funções → `role-ssm-demo-ec2` → aba Permissões**.
- **Resultado esperado:** `AmazonSSMManagedInstanceCore` anexada.

![Função IAM com a política gerenciada AmazonSSMManagedInstanceCore](imagens/imagem%20(29).png)

### Passo 1.3 — Confirmar a função associada à instância
- **Onde:** **EC2 → Instâncias →** a instância **→ aba Segurança**.
- **Resultado esperado:** o campo **Função do IAM** mostra `role-ssm-demo-ec2`.

### Passo 1.4 — Confirmar a conectividade
- **O que verificar:** a VPC padrão fornece saída pela internet (Internet Gateway + IP público). Não é preciso criar NAT nem endpoints.

### Passo 1.5 — Confirmar a instância gerenciada
- **Onde:** **Systems Manager → Fleet Manager**.
- **Resultado esperado:** a instância com **Status do ping = Online**.

### Passo 1.6 — Abrir a sessão
- **Onde:** **Systems Manager → Session Manager (Gerenciador de sessões) → Iniciar sessão**.
- **O que fazer:** marque a `ec2-ssm-demo-1` e clique em **Iniciar sessão**. Não existe campo para chave SSH.
- **Resultado esperado:** abre um terminal no navegador. Teste `whoami` e `hostname`.
- **Erro comum:** a instância não aparece na lista. Ela não está Online (volte ao passo 0.5).
- **Erro comum:** `AccessDenied` ao iniciar. Sua identidade não tem `ssm:StartSession`; peça a permissão ou use um usuário administrador.

### Passo 1.7 — Provar que não há porta 22 aberta
- **Onde:** **EC2 → Instâncias →** a instância **→ Segurança →** clique no grupo de segurança **→ Regras de entrada**.
- **Resultado esperado:** **nenhuma regra de entrada**, e a sessão do passo 1.6 continua funcionando. Esse é o resultado central da Parte 1.

### Passo 1.8 — (Opcional) Registrar as sessões em log
- **Onde:** **Session Manager → Preferências → Editar**.
- **O que fazer:** habilite o envio de logs para um bucket S3 e/ou grupo de logs do CloudWatch já existentes, e clique em **Salvar**.

---

## Parte 2 — Run Command (comando remoto sem sessão)

### Passo 2.1 — Abrir o Run Command
- **Onde:** **Systems Manager → Run Command → Executar comando**.

### Passo 2.2 — Escolher o documento
- **O que fazer:** na busca de documentos, digite `AWS-RunShellScript` e selecione-o.

### Passo 2.3 — Informar o comando
- **O que fazer:** cole no campo **Commands** o script de leitura abaixo (não altera nada):

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "== Versao do sistema operacional =="
cat /etc/os-release | grep PRETTY_NAME
echo "== Uso de disco =="
df -h /
echo "== Memoria =="
free -h
```

### Passo 2.4 — Escolher o destino
- **O que fazer:** em **Destinos**, selecione **Escolher instâncias manualmente** e marque a `ec2-ssm-demo-1`.
- **Erro comum:** a instância não aparece na lista. Ela não está Online.

### Passo 2.5 — Executar e acompanhar
- **O que fazer:** clique em **Executar**. Na página de detalhes, atualize até o status ficar **Êxito** (`Success`).
- **Resultado esperado:** status `Success`, sem abrir sessão interativa.

![Run Command: comando com status Êxito em 1 destino](imagens/imagem%20(3).png)

### Passo 2.6 — Ver a saída
- **O que fazer:** no destino, clique em **Ver saída**. Você verá versão do SO, disco e memória.

![Saída do Run Command na instância 1: versão do sistema operacional e uso de disco, com status Êxito](imagens/imagem%20(2).png)

![Saída completa do Run Command: versão do sistema, uso de disco e memória](imagens/imagem%20(4).png)

### Passo 2.7 — Consultar o histórico
- **Onde:** **Run Command → aba Histórico de comandos** (Command history). Localize o **Command ID** e confira o `Success`.

![Histórico de comandos do Run Command, com o comando mais recente em Êxito](imagens/imagem%20(5).png)

### Permissão mínima do Run Command

Use para quem só pode executar este comando nesta instância (troque o ID pelo real):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ssm:<REGIAO_AWS>::document/AWS-RunShellScript",
        "arn:aws:ec2:<REGIAO_AWS>:<ID_CONTA>:instance/i-0123456789abcdef0"
      ]
    }
  ]
}
```

---

## Parte 3 — Parameter Store (parte principal)

### Bloco A — Parâmetros `String` e `StringList`

#### Passo 3.1 — Abrir o Parameter Store
- **Onde:** **Systems Manager → Parameter Store**.

#### Passo 3.2 — Criar `/delivery/dev/ambiente` (String)
- **Onde:** **Parameter Store → Criar parâmetro**.
- **O que preencher:**
  - **Nome:** `/delivery/dev/ambiente`
  - **Camada:** **Padrão** (Standard)
  - **Tipo:** **String**; **Tipo de dados:** `text`
  - **Valor:** `desenvolvimento`
- Clique em **Criar parâmetro**.
- **Resultado esperado:** o parâmetro aparece na lista com **Versão 1**.

#### Passo 3.3 — Criar `/delivery/dev/database/host` (String)
- Mesmo procedimento do 3.2: **Nome** `/delivery/dev/database/host`, **Tipo** String, **Valor** `<HOST_FICTICIO>`.

#### Passo 3.4 — Criar `/delivery/dev/database/usuario` (String)
- **Nome** `/delivery/dev/database/usuario`, **Tipo** String, **Valor** `<USUARIO_FICTICIO>`.

#### Passo 3.5 — Criar `/delivery/dev/notificacoes` (StringList)
- **Nome** `/delivery/dev/notificacoes`, **Tipo** **StringList**, **Valor** `email1,email2` (separados por vírgula, **sem espaços**).

#### Passo 3.6 — Conferir um `String`
- **O que fazer:** clique em `/delivery/dev/ambiente`.
- **Resultado esperado:** valor em claro `desenvolvimento` e versão `1`.

#### Passo 3.7 — Conferir o `StringList`
- **O que fazer:** clique em `/delivery/dev/notificacoes`.
- **Resultado esperado:** a lista em claro e versão `1`.

#### Passo 3.8 — Listar por caminho
- **O que fazer:** na lista de parâmetros, filtre por **Nome** que comece com `/delivery/dev/`.
- **Resultado esperado:** aparecem os 4 parâmetros criados. Isso equivale à API `ssm:GetParametersByPath`.
- **Erro comum:** tentar criar um nome que já existe mostra `ParameterAlreadyExists`. É uma proteção; o parâmetro continua inalterado.

### Bloco B — `SecureString` com chave KMS própria (CMK) e permissões

> ⚠️ **Custo:** a chave KMS custa cerca de **USD 1.00 por mês** enquanto existir, mesmo sem uso. Ela só é encerrada pelo agendamento de exclusão (passo L.2).

#### Passo 3.9 — Criar a chave KMS
- **Onde:** **AWS KMS → Chaves gerenciadas pelo cliente → Criar chave**.
- **O que preencher:**
  1. **Tipo de chave:** **Simétrica**; **Uso da chave:** **Criptografar e descriptografar**.
  2. **Avançar**. **Alias:** `delivery-dev-securestring`; **Descrição:** `CMK para o SecureString`.
  3. **Avançar**. **Administradores da chave:** seu usuário.
  4. **Avançar**. **Usuários da chave:** marque a função `role-ssm-demo-ec2`.
  5. **Avançar → Concluir**.
- **Resultado esperado:** a chave aparece como **Habilitada**. Abra-a e anote o **ID da chave** (`<ID_DA_CMK>`) e o **ARN**.

![Chave KMS gerenciada pelo cliente: habilitada, com alias, ARN e política de chaves](imagens/imagem%20(33).png)

#### Passo 3.10 — Criar `/delivery/dev/database/senha` (SecureString)
- **Onde:** **Parameter Store → Criar parâmetro**.
- **O que preencher:**
  - **Nome:** `/delivery/dev/database/senha`; **Camada:** Padrão
  - **Tipo:** **SecureString**
  - **Origem da chave KMS:** **Minha conta atual**; **Chave KMS:** `alias/delivery-dev-securestring` (**não** use `alias/aws/ssm`)
  - **Valor:** `<SENHA_FICTICIA>`
- **Resultado esperado:** o parâmetro aparece como `SecureString`, versão `1`.

![Parameter Store: os cinco parâmetros de /delivery/dev](imagens/imagem%20(34).png)

#### Passo 3.11 — Ver o valor cifrado
- **O que fazer:** abra o parâmetro **sem** marcar **Mostrar valor descriptografado**.
- **Resultado esperado:** o valor aparece mascarado (`********`), não a senha. Ela só é mostrada depois de marcar **Mostrar valor descriptografado** (passo 3.12).

![Parâmetro /delivery/dev/database/senha do tipo SecureString, com o valor oculto](imagens/imagem%20(6).png)

#### Passo 3.12 — Ver o valor em claro
- **O que fazer:** marque **Mostrar valor descriptografado**.
- **Resultado esperado:** `<SENHA_FICTICIA>` em claro, **se** sua identidade tiver `kms:Decrypt` na chave.
- **Erro comum:** `AccessDenied` mencionando `kms:Decrypt`. Falta a permissão na identidade ou na política da chave.

#### Passo 3.13 — Política de identidade da função (menor privilégio)
- **Onde:** **IAM → Funções → `role-ssm-demo-ec2` → Permissões → Adicionar permissões → Criar política em linha → aba JSON**.
- **O que preencher:** cole o JSON (troque `<REGIAO_AWS>`, `<ID_CONTA>` e `<ID_DA_CMK>`), dê o nome `ssm-demo-parameter-store-leitura` e clique em **Criar política**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
      "Resource": ["arn:aws:ssm:<REGIAO_AWS>:<ID_CONTA>:parameter/delivery/dev", "arn:aws:ssm:<REGIAO_AWS>:<ID_CONTA>:parameter/delivery/dev/*"] },
    { "Effect": "Allow", "Action": "kms:Decrypt", "Resource": "arn:aws:kms:<REGIAO_AWS>:<ID_CONTA>:key/<ID_DA_CMK>" }
  ]
}
```

- **Resultado esperado:** a política aparece em linha na função.

![Editor de política em linha: ssm:GetParameter* em /delivery/dev e kms:Decrypt na chave](imagens/imagem%20(28).png)

#### Passo 3.14 — Política da chave KMS
- **Onde:** **AWS KMS → sua chave → aba Política de chave → Editar**.
- **O que fazer:** dentro de `"Statement": [ ... ]`, adicione (com vírgula entre as instruções) e clique em **Salvar alterações**:

```json
{
  "Sid": "PermitirDecryptAoIamRoleDaFrota",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::<ID_CONTA>:role/<NOME_DO_IAM_ROLE>" },
  "Action": "kms:Decrypt",
  "Resource": "*"
}
```

- **Erro comum:** JSON inválido por falta de vírgula entre as instruções.
- **Por que as duas políticas:** a identidade diz o que a função **pode pedir**; a política da chave diz quem **pode usar a chave**. As duas precisam permitir.

### Bloco C — Versionamento e uso na EC2

#### Passo 3.15 — Atualizar um parâmetro
- **O que fazer:** **Parameter Store →** `/delivery/dev/ambiente` **→ Editar**; **Valor** `homologacao`; **Salvar alterações**.
- **Resultado esperado:** a versão passa a `2`.

#### Passo 3.16 — Ver o histórico
- **O que fazer:** abra o parâmetro e a aba **Histórico**.
- **Resultado esperado:** versão `1` (`desenvolvimento`) e `2` (`homologacao`).

![Histórico do parâmetro /delivery/dev/ambiente com as versões 1 e 2](imagens/imagem%20(7).png)

#### Passo 3.17 — Recuperar a versão atual
- **Resultado esperado:** sem informar versão, o valor atual (`homologacao`, versão `2`) é retornado.

#### Passo 3.18 — Ler os parâmetros de dentro da EC2
- **Onde:** **Session Manager → Iniciar sessão** na `ec2-ssm-demo-1`.
- **O que fazer:** cole o script (somente leitura) e depois digite `echo $?`:

```bash
#!/usr/bin/env bash
set -euo pipefail
REGIAO="<REGIAO_AWS>"
aws ssm get-parameter --name "/delivery/dev/ambiente" --region "${REGIAO}" \
  --query 'Parameter.Value' --output text
aws ssm get-parameter --name "/delivery/dev/database/senha" --with-decryption \
  --region "${REGIAO}" --query 'Parameter.Value' --output text
aws ssm get-parameters-by-path --path "/delivery/dev/" --recursive \
  --with-decryption --region "${REGIAO}" \
  --query 'Parameters[].Name' --output text
```

- **Resultado esperado:** imprime `homologacao`, a senha em claro e os nomes dos parâmetros; `echo $?` mostra `0`.
- **Erro comum:** `AccessDenied`. Revise os passos 3.13 e 3.14.

> **Conceitual:** a camada Padrão (até 4 KB, sem custo) difere da Avançada (até 8 KB, políticas de parâmetro, custo mensal). Atualizar um parâmetro **não** rotaciona a senha no banco real; para rotação automática, use o Secrets Manager.

![Sessão do Session Manager na instância 2, lendo os parâmetros com a AWS CLI](imagens/imagem%20(8).png)

---

## Parte 4 — Automação e aplicação em 2 instâncias (por tag)

> **Requisito:** Parte 3 concluída (parâmetros, chave KMS e passos 3.13 e 3.14), pois a aplicação lê `/delivery/dev/`.

### Passo 4.1 — Conferir as tags
- **Onde:** **EC2 → Instâncias →** cada instância **→ aba Tags**.
- **Resultado esperado:** `Ambiente = ssm-demo` nas duas. Se faltar, **Gerenciar tags**. Maiúsculas e minúsculas importam.

![Instância 1 selecionada, com a tag Ambiente na aba Tags](imagens/imagem%20(9).png)

![Instância 2 selecionada, com a tag Ambiente na aba Tags](imagens/imagem%20(10).png)

### Passo 4.2 — Rodar um comando nas duas instâncias de uma vez
- **Onde:** **Systems Manager → Run Command → Executar comando**.
- **O que preencher:**
  - **Documento:** `AWS-RunShellScript`
  - **Destinos:** **Especificar tags de instância** → **Chave** `Ambiente`, **Valor** `ssm-demo` → **Adicionar**
  - **Controles de taxa:** **Simultaneidade** `2` destinos; **Limite de erros** `1` erro
  - **Commands:**

```bash
#!/usr/bin/env bash
set -euo pipefail
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
hostname
curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id; echo
date -u
```

- Clique em **Executar**.
- **Resultado esperado:** um único Command ID com **2 destinos** em `Success`.

![Run Command por tag: comando enviado com êxito para os 2 destinos](imagens/imagem%20(11).png)

### Passo 4.3 — Comparar a saída
- **O que fazer:** em cada destino, clique em **Ver saída**.
- **Resultado esperado:** mesmo formato, mas **hostname e ID diferentes** em cada instância.

![Detalhes do comando: os 2 destinos concluídos com status Êxito](imagens/imagem%20(13).png)

![Saída do comando na instância 1: hostname, ID da instância e data/hora](imagens/imagem%20(12).png)

![Saída do comando na instância 2: hostname e ID diferentes dos da instância 1](imagens/imagem%20(14).png)

### Passo 4.4 — Falha proposital (limite de erros)
- **O que fazer:** repita o passo 4.2 com **Commands** = `exit 1`, **Simultaneidade** `1` e **Limite de erros** `1`.
- **Resultado esperado:** o comando termina **Com falha** (código de resposta `1`) e a saída de cada destino mostra `failed to run commands: exit status 1`. O `exit 1` não altera nada nas máquinas.
- **Sobre o limite de erros:** com **Simultaneidade** `1` e **Limite de erros** `1`, o Systems Manager trata um destino por vez e deixa de enviar o comando aos demais depois do primeiro erro (eles podem aparecer como `Cancelled`). Isso evita propagar uma mudança com defeito para toda a frota. Nas imagens abaixo, os dois destinos iniciaram no mesmo horário e falharam; se isso acontecer com você, confira se o campo **Simultaneidade** ficou em `1`.

![Comando com exit 1: as duas instâncias terminam com status Com falha](imagens/imagem%20(15).png)

![Saída da instância 1: failed to run commands: exit status 1](imagens/imagem%20(16).png)

![Saída da instância 2: failed to run commands: exit status 1](imagens/imagem%20(17).png)

![Histórico de comandos: a execução com falha aparece no topo, acima das execuções em Êxito](imagens/imagem%20(18).png)

### Passo 4.5 — Implantar a aplicação com o State Manager
- **Onde:** **Systems Manager → State Manager → Criar associação**.
- **O que preencher:**
  - **Nome:** `ssm-demo-implanta-app`
  - **Documento:** `AWS-RunShellScript`
  - **Parâmetros → Commands:** cole o conteúdo completo do arquivo `app/deploy-app.sh` (veja o quadro abaixo)
  - **Destinos:** **Especificar tags de instância** → `Ambiente` = `ssm-demo`
  - **Agenda:** **Por agendamento** → **Expressão de taxa** `rate(30 minutes)`; deixe **desmarcado** "aplicar somente uma vez"
- Clique em **Criar associação**.
- **Resultado esperado:** em poucos minutos, a aba **Recursos** (ou **Histórico de execuções**) mostra os 2 destinos em `Success`, com a mensagem `OK: delivery-config em execucao na porta 8080`.
- **Erro comum:** destino com falha. Abra a saída do destino; o script mostra o status do serviço e o motivo.

> ### Use obrigatoriamente o código do arquivo `app/deploy-app.sh`
>
> Todo o código da aplicação está no arquivo **`app/deploy-app.sh`**, nesta pasta do laboratório. Abra o arquivo, **copie o conteúdo inteiro** (do `#!/usr/bin/env bash` até o final) e cole no campo **Commands**. Não escreva outro script nem copie só um pedaço.
>
> O que ele faz dentro de cada instância:
> - cria um usuário de sistema sem login (`deliveryapp`) e grava a aplicação Python em `/opt/delivery-config`;
> - cria e inicia o serviço `systemd` `delivery-config` na porta `8080`;
> - testa `/saude` no final e falha (com o motivo) se a aplicação não responder.
>
> Ele **não cria recursos AWS** e é **idempotente**: pode rodar várias vezes e só reinicia o serviço quando algo mudou.

![State Manager: recursos da associação, as duas instâncias com status Êxito](imagens/imagem%20(19).png)

![Resumo da execução da associação: Success](imagens/imagem%20(20).png)

![Execução da associação: os dois destinos com status Success](imagens/imagem%20(21).png)

![Saída da implantação na instância 2: OK, delivery-config em execução na porta 8080](imagens/imagem%20(22).png)

![Histórico de execução da associação: status Êxito e Success:2](imagens/imagem%20(23).png)

> A mensagem `Created symlink ...` no painel **Error** vem do systemd ao habilitar o serviço. Ela não indica falha: o status é Êxito.

### Passo 4.6 — Testar a aplicação nas duas instâncias
- **Onde:** **Run Command → Executar comando** (`AWS-RunShellScript`, destino por tag `Ambiente=ssm-demo`).
- **Commands:**

```bash
#!/usr/bin/env bash
set -euo pipefail
curl -fs http://127.0.0.1:8080/saude; echo
curl -fs http://127.0.0.1:8080/config; echo
```

- **Resultado esperado:** `/saude` responde `{"status": "ok"}`. `/config` mostra **hostname, instância e zona diferentes** em cada máquina, e `ambiente`, `database_host`, `database_usuario` e `notificacoes` vindos do Parameter Store, além de `senha_carregada: true` e `senha_tamanho` (ex.: `19`). **A senha não aparece.**
- **Se `erro_parameter_store` aparecer:** falta permissão. Revise os passos 3.13 e 3.14.

![Sessão na instância 1: respostas de /saude e /config da aplicação](imagens/imagem%20(24).png)

### Passo 4.7 — (Opcional) Abrir no navegador
- **Onde:** **EC2 → Grupos de segurança → `sg-ssm-demo` → Regras de entrada → Editar regras de entrada → Adicionar regra**.
- **O que preencher:** **Tipo** TCP personalizado, **Porta** `8080`, **Origem** **Meu IP**. **Salvar regras**.
- **Resultado esperado:** `http://<IPV4_PUBLICO>:8080` mostra a tabela com os dados de cada instância.
- ⚠️ **Depois, remova a regra** (Editar regras de entrada → **Excluir** → **Salvar**). Nunca use `0.0.0.0/0`. A conexão é HTTP sem criptografia, aceitável só neste teste.

![Detalhes do security group da instância, com 1 regra de entrada e 1 de saída](imagens/imagem%20(30).png)

![Aplicação no navegador, instância 1: ambiente homologacao e senha carregada, sem exibir a senha](imagens/imagem%20(25).png)

![Aplicação no navegador, instância 2: mesma configuração, com hostname e ID próprios](imagens/imagem%20(26).png)

### Passo 4.8 — Mudar a configuração sem reimplantar
- **O que fazer:** **Parameter Store →** `/delivery/dev/ambiente` **→ Editar**, **Valor** `producao`, **Salvar alterações**. Espere cerca de 30 segundos e repita o passo 4.6.
- **Resultado esperado:** `ambiente` passa a mostrar `producao` nas duas instâncias, sem nenhuma reimplantação.

![Aplicação na instância 1 depois da mudança: ambiente producao](imagens/imagem%20(32).png)

![Aplicação na instância 2 depois da mudança: ambiente producao](imagens/imagem%20(31).png)

### Passo 4.9 — Provocar um desvio e deixar o State Manager corrigir
- **O que fazer:**
  1. **Session Manager →** sessão na `ec2-ssm-demo-2` e execute:

```bash
sudo systemctl stop delivery-config
sudo rm /opt/delivery-config/app.py
curl -s --max-time 2 http://127.0.0.1:8080/saude || echo "aplicacao fora do ar"
```

  2. **State Manager →** selecione `ssm-demo-implanta-app` → **Aplicar associação agora**.
  3. Quando o status voltar a `Success`, na sessão rode `curl -s http://127.0.0.1:8080/saude` e `ls /opt/delivery-config/app.py`.
- **Resultado esperado:** primeiro "aplicacao fora do ar"; depois da reaplicação, `{"status": "ok"}` e o arquivo existe de novo.

### Passo 4.10 — Seleção por tag é dinâmica
- **O que fazer:** em **EC2 →** `ec2-ssm-demo-2` **→ Tags → Gerenciar tags**, remova a tag `Ambiente`. Rode o comando do passo 4.6 por tag.
- **Resultado esperado:** só a `ec2-ssm-demo-1` é executada.
- ⚠️ **Restaure a tag** `Ambiente = ssm-demo` na `-2` antes de continuar (a associação também usa essa tag).

### Passo 4.11 — (Opcional) Automation
- **Onde:** **Systems Manager → Automação → Executar automação**.
- **O que preencher:** documento `AWS-RestartEC2Instance`, **Execução simples**, **InstanceId** da `ec2-ssm-demo-2`, `AutomationAssumeRole` vazio.
- **Resultado esperado:** passos em `Success`; a instância reinicia e volta Online. A aplicação sobe sozinha (serviço habilitado).
- **Atenção:** o reinício encerra sessões abertas nessa instância.

---

## Limpeza (ordem por dependência)

> ⚠️ Faça a limpeza ao terminar: as 2 EC2, os volumes, os IPv4 públicos e a chave KMS geram cobrança enquanto existirem.

### Passo L.0 — Remover a regra da porta 8080 (se você fez o passo 4.7)
- **Onde:** **EC2 → Grupos de segurança → `sg-ssm-demo` → Editar regras de entrada** → **Excluir** a regra → **Salvar**.

### Passo L.1 — Excluir a associação do State Manager
- **Onde:** **Systems Manager → State Manager →** marque `ssm-demo-implanta-app` → **Excluir**.
- **Resultado esperado:** a associação some da lista (senão ela continua reexecutando na agenda).

### Passo L.2 — Excluir os parâmetros
- **Onde:** **Parameter Store →** filtre por `/delivery/dev/`, marque os **5** parâmetros e clique em **Excluir**.

### Passo L.3 — Agendar a exclusão da chave KMS
- **Onde:** **AWS KMS → Chaves gerenciadas pelo cliente →** a chave **→ Ações da chave → Programar exclusão da chave**.
- **O que preencher:** período de espera entre **7 e 30 dias** (use `7`) e marque a confirmação.
- **Resultado esperado:** estado **Exclusão pendente**. Durante a espera ainda é possível cancelar. Depois, a exclusão é definitiva.

### Passo L.4 — Remover os ajustes de IAM do laboratório
- **Onde:** **IAM → Funções → `role-ssm-demo-ec2` → Permissões →** política em linha `ssm-demo-parameter-store-leitura` → **Remover**.
- **Chave KMS:** se ainda editável, em **Política de chave → Editar**, remova a instrução `PermitirDecryptAoIamRoleDaFrota`. Se a chave já estiver em exclusão pendente e não permitir edição, pule: a instrução some com a chave.

### Passo L.5 — Encerrar as duas EC2
- **Onde:** **EC2 → Instâncias →** marque `ec2-ssm-demo-1` e `ec2-ssm-demo-2` **→ Estado da instância → Encerrar (excluir) instância**.
- **Resultado esperado:** estado **Encerrada**. Em **EC2 → Volumes**, confirme que não sobrou volume do laboratório. **Parar** a instância não basta: o volume continua cobrando.

### Passo L.6 — Excluir o security group
- **Onde:** **EC2 → Grupos de segurança →** `sg-ssm-demo` **→ Ações → Excluir grupos de segurança**.
- **Erro comum:** `DependencyViolation`. A instância ainda está encerrando; aguarde e tente de novo.

### Passo L.7 — Excluir a função IAM
- **Onde:** **IAM → Funções →** `role-ssm-demo-ec2` **→ Excluir**; digite o nome para confirmar.

### Passo L.8 — Verificação final
- [ ] Associação do State Manager ausente
- [ ] Os 5 parâmetros `/delivery/dev/*` ausentes
- [ ] Chave KMS em **Exclusão pendente**
- [ ] As duas EC2 **Encerradas** e nenhum volume do laboratório
- [ ] Security group `sg-ssm-demo` e função `role-ssm-demo-ec2` ausentes

> Se uma exclusão falhar, leia a mensagem, corrija a causa e repita **apenas** aquele recurso. Não refaça os passos dos recursos que já foram excluídos.
