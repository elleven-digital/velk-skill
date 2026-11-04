# Publicar a skill

## Uma vez, na Cloudflare

1. **Bucket novo** no R2: `velk-skill`.
   Separado do `velk-releases` de propósito — no R2 o domínio customizado
   aponta para um bucket inteiro, não para uma pasta. Compartilhando, o
   `releases.velkcms.com` também serviria os tarballs da skill.

2. **Domínio customizado** `skill.velkcms.com` nesse bucket.
   Mesmo caminho do `releases.velkcms.com`: R2 → Settings → Custom Domains.

3. **Regra de rewrite** para a raiz servir o `index.html`.

   O R2 não faz isso sozinho: `https://skill.velkcms.com/` procura um objeto
   de chave vazia e devolve 404. Sem a regra, a instalação precisa da URL
   inteira do tarball — com ela, basta `skill.velkcms.com`.

   Cloudflare → o domínio `velkcms.com` → **Rules** → **Redirect Rules** →
   criar regra:

   - **Quando:** `Hostname` igual a `skill.velkcms.com` **e** `URI Path`
     igual a `/`
   - **Então:** redirecionar (302) para `https://skill.velkcms.com/index.html`

   Alternativa sem redirecionamento visível: **Transform Rules → Rewrite URL**,
   reescrevendo o path `/` para `/index.html`. As duas funcionam; a segunda
   mantém a URL limpa na barra do navegador.

4. **`.release.env`** na raiz deste repositório (já está no `.gitignore`):

   ```
   R2_ENDPOINT="https://<accountid>.r2.cloudflarestorage.com"
   R2_BUCKET="velk-skill"
   RELEASE_BASE_URL="https://skill.velkcms.com"
   AWS_ACCESS_KEY_ID="..."
   AWS_SECRET_ACCESS_KEY="..."
   AWS_DEFAULT_REGION="auto"
   ```

   Pode reaproveitar as credenciais do engine se elas tiverem acesso ao
   bucket novo — ou criar um token só para ele, que é mais limpo.


## A cada versão

O `main` do GitHub é o que o plugin entrega: quem instala do zero recebe a
pasta `plugin/` do `main` como está. Trabalho em andamento fica num branch até
o release. Só `plugin/` chega a quem instala; testes e ferramentas ficam na raiz.

```bash
# 1. versão nos dois lugares — quem tem o plugin só recebe a atualização
#    quando o "version" do .claude-plugin/plugin.json muda
echo "v1.6.0" > VERSION        # e "version": "1.6.0" em plugin/.claude-plugin/plugin.json

# 2. conferir o marketplace, o plugin e os testes
claude plugin validate .
claude plugin validate plugin --profile directory --strict
bash tests/run.sh

# 3. commit + tag
git add -A && git commit -m "release: v1.6.0"
git tag -a v1.6.0 -m "v1.6.0"
git push origin main && git push origin v1.6.0

# 4. publicar o pacote do skill.velkcms.com
tools/release v1.6.0
```

Sempre `--dry-run` antes, se estiver em dúvida — ele monta tudo em `dist/`
sem subir nada. O `tools/release` recusa publicar se o `plugin.json` da tag
tiver outra versão, ou se não conseguir ler a lista de versões publicada.

## Diretório do Claude

A listagem acompanha o `main`. Cada versão nova passa pela verificação
automática do diretório e, enquanto a publicação automática estiver
desligada, espera aprovação no portal de envio. A versão anterior continua no
ar até a nova ser aprovada.

## Conferir depois

```bash
curl -s https://skill.velkcms.com/versions.json | jq .latest
curl -sI https://skill.velkcms.com/velk-skill-latest.tar.gz | head -1
```

## Diretório da OpenAI (ChatGPT e Codex)

O mesmo plugin, embalado no formato do Codex por `tools/codex-package`:
`.codex-plugin/plugin.json` (o `codex/plugin.json` + a versão do `VERSION`), a
skill em `skills/velk/` e os ícones em `assets/`. O marketplace do Claude
sozinho não basta: o Codex até instala o plugin, mas só carrega skills de
`skills/<nome>/SKILL.md`, e a nossa fica na raiz de `plugin/`.

O pacote leva `"requires_local_executor": true` — os scripts rodam no
computador da pessoa, então o diretório mostra **Desktop only** e só instala
pelo app de desktop. Se o portal recusar esse campo, a OpenAI pede o ID da
organização para liberar o envio.

### Uma vez

No platform.openai.com, a verificação de identidade (pessoa ou empresa) nas
configurações da organização. Quem envia é o dono da organização, ou alguém
com a permissão **Apps Management Write**.

### A cada versão, depois da tag

```bash
tools/codex-package v1.6.0      # dist/velk-codex-v1.6.0.zip e dist/codex/marketplace/
```

Testar antes no Codex do app do ChatGPT (o CLI vem dentro do app):

```bash
C=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
$C plugin marketplace add "$PWD/dist/codex/marketplace"
$C plugin add velk@velk
(cd "$(mktemp -d)" && $C debug prompt-input | grep -c 'velk:velk')   # 1 ou mais: a skill entrou
$C plugin remove velk@velk && $C plugin marketplace remove velk
```

Enviar: platform.openai.com/plugins → **Upload new or existing plugin** → o
ZIP → checagens automáticas → **Submit for review** → depois de aprovado,
**Publish plugin**. Cada versão é um ZIP novo, com revisão nova: aqui não há
publicação automática pelo `main`.
