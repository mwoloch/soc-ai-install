#!/usr/bin/env bash
# =============================================================================
# SOC AI Platform — Instalator
# Użycie: bash install.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}✗ BŁĄD:${NC} $*"; exit 1; }

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       SOC AI Platform — Instalator           ║"
echo "  ║       InfoTech Sp. z o.o.                    ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

LICENSE_SERVER="https://licencje.infotech.biz.pl"

# ─── Sprawdź OS ───────────────────────────────────────────────────────────────
[[ "$OSTYPE" == "linux-gnu"* ]] || die "Wymagany Linux. Wykryto: $OSTYPE"

# ─── Sprawdź/Zainstaluj Docker ────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Docker nie znaleziony. Instaluję..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker --now 2>/dev/null || true
    ok "Docker zainstalowany."
else
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
fi

if ! docker compose version &>/dev/null 2>&1; then
    die "Wymagany Docker Compose v2 (plugin). Zaktualizuj Docker do wersji 23+."
fi
ok "Docker Compose $(docker compose version --short)"

# ─── Instaluj wymagane narzędzia ──────────────────────────────────────────────
for tool in curl tar openssl; do
    command -v "$tool" &>/dev/null || { apt-get update -qq && apt-get install -y -qq "$tool"; }
done

# ─── Weryfikacja licencji i pobranie kodu ─────────────────────────────────────
INSTALL_DIR="${SOC_INSTALL_DIR:-/opt/soc-ai-platform}"
GITHUB_REPO="mwoloch/automatyzacja_AI"

if [[ -f "docker-compose.yml" && -d "backend" ]]; then
    # ── Ścieżka 1: uruchomiono z katalogu z już pobranym kodem ────────────────
    INSTALL_DIR="$(pwd)"
    info "Instalacja z katalogu: $INSTALL_DIR"

else
    # ── Wybór metody instalacji ───────────────────────────────────────────────
    # Token może być przekazany przez zmienną środowiskową (cicha instalacja)
    TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

    if [[ -z "$TOKEN" ]]; then
        echo ""
        echo -e "${BOLD}Metoda instalacji:${NC}"
        echo "  1) Token dostępu GitHub  (dla autoryzowanych instalacji)"
        echo "  2) Klucz licencyjny      (pobieranie z serwera dystrybucji)"
        echo ""
        read -rp "  Wybierz [1/2]: " INSTALL_METHOD
        INSTALL_METHOD="${INSTALL_METHOD:-1}"

        if [[ "$INSTALL_METHOD" == "1" ]]; then
            echo ""
            echo -e "  Wygeneruj token na: ${BOLD}https://github.com/settings/tokens${NC}"
            echo "  (Fine-grained token, uprawnienie: Contents = Read-only)"
            echo ""
            read -rsp "  GitHub Token (wpisywanie ukryte): " TOKEN
            echo ""
            [[ -n "$TOKEN" ]] || die "Token jest wymagany."
        fi
    else
        INSTALL_METHOD="1"
        info "Używam tokenu GitHub z zmiennej środowiskowej."
    fi

    if [[ "${INSTALL_METHOD:-1}" == "1" ]]; then
        # ── Ścieżka 2: klonowanie z prywatnego repo GitHub ────────────────────
        if [[ -d "$INSTALL_DIR/.git" ]]; then
            info "Aktualizuję istniejącą instalację w: $INSTALL_DIR ..."
            cd "$INSTALL_DIR"
            git remote set-url origin "https://oauth2:${TOKEN}@github.com/${GITHUB_REPO}.git"
            git pull --quiet || die "Błąd aktualizacji repozytorium. Sprawdź token."
            ok "Repozytorium zaktualizowane."
        else
            info "Klomuję repozytorium do: $INSTALL_DIR ..."
            mkdir -p "$INSTALL_DIR"
            git clone --quiet "https://oauth2:${TOKEN}@github.com/${GITHUB_REPO}.git" "$INSTALL_DIR" \
                || die "Błąd klonowania. Sprawdź poprawność tokenu i dostęp do repozytorium."
            ok "Kod pobrany do: $INSTALL_DIR"
        fi
        INSTALL_DIR="$(realpath "$INSTALL_DIR")"

        # ── Klucz licencyjny (aktywacja aplikacji) ────────────────────────────
        LICENSE_KEY="${SOC_LICENSE_KEY:-}"
        if [[ -z "$LICENSE_KEY" ]]; then
            echo ""
            echo -e "${BOLD}Aktywacja licencji aplikacji:${NC}"
            read -rp "  Klucz licencyjny SOC AI Platform: " LICENSE_KEY
            [[ -n "$LICENSE_KEY" ]] || die "Klucz licencyjny jest wymagany."
        fi

    else
        # ── Ścieżka 3: serwer licencji (dystrybucja komercyjna) ───────────────
        echo ""
        echo -e "${BOLD}Aktywacja licencji:${NC}"
        read -rp "  Klucz licencyjny SOC AI Platform: " LICENSE_KEY
        [[ -n "$LICENSE_KEY" ]] || die "Klucz licencyjny jest wymagany."

        MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || hostname | sha256sum | cut -c1-32)"

        info "Weryfikuję licencję na serwerze..."
        RESPONSE=$(curl -fsSL \
            -H "Content-Type: application/json" \
            -d "{\"license_key\": \"${LICENSE_KEY}\", \"machine_id\": \"${MACHINE_ID}\"}" \
            "${LICENSE_SERVER}/api/download" 2>&1) || die "Nie można połączyć się z serwerem licencji. Sprawdź połączenie z internetem."

        if echo "$RESPONSE" | grep -q '"error"'; then
            ERR=$(echo "$RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)
            die "Serwer licencji: $ERR"
        fi

        DOWNLOAD_URL=$(echo "$RESPONSE" | grep -o '"download_url":"[^"]*"' | cut -d'"' -f4)
        VERSION=$(echo "$RESPONSE" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        CHECKSUM=$(echo "$RESPONSE" | grep -o '"sha256":"[^"]*"' | cut -d'"' -f4)

        [[ -n "$DOWNLOAD_URL" ]] || die "Serwer licencji nie zwrócił URL do pobrania. Sprawdź klucz."
        ok "Licencja aktywna. Wersja: ${VERSION}"

        TMPDIR_WORK=$(mktemp -d)
        TARBALL="$TMPDIR_WORK/soc-ai-platform-${VERSION}.tar.gz"

        info "Pobieram SOC AI Platform v${VERSION}..."
        curl -fL --progress-bar -o "$TARBALL" "$DOWNLOAD_URL" || die "Błąd pobierania archiwum."

        if [[ -n "$CHECKSUM" ]]; then
            ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
            [[ "$ACTUAL" == "$CHECKSUM" ]] || die "Błąd integralności archiwum (SHA256 nie pasuje)."
            ok "Integralność archiwum OK."
        fi

        mkdir -p "$INSTALL_DIR"
        tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
        rm -rf "$TMPDIR_WORK"
        ok "Kod rozpakowany do: $INSTALL_DIR"
    fi
fi

cd "$INSTALL_DIR"

# ─── Konfiguracja interaktywna ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Konfiguracja instalacji:${NC}"
echo "(Naciśnij Enter aby użyć wartości domyślnej)"
echo ""

read -rp "  Adres/domena serwera  [$(hostname -I | awk '{print $1}')]: " HOST_INPUT
HOST="${HOST_INPUT:-$(hostname -I | awk '{print $1}')}"

read -rp "  Port dashboardu       [5000]: " DASH_PORT_INPUT
DASH_PORT="${DASH_PORT_INPUT:-5000}"

read -rp "  Port API (backend)    [8000]: " API_PORT_INPUT
API_PORT="${API_PORT_INPUT:-8000}"

echo ""

# ─── Generuj sekrety ──────────────────────────────────────────────────────────
info "Generuję klucze kryptograficzne..."
DB_PASSWORD=$(openssl rand -hex 20)
JWT_SECRET=$(openssl rand -hex 32)
FLASK_SECRET=$(openssl rand -hex 32)

# ─── Utwórz .env dla backendu ─────────────────────────────────────────────────
info "Tworzę backend/.env ..."
cat > backend/.env << EOF
DATABASE_URL=postgresql+asyncpg://soc_user:${DB_PASSWORD}@db:5432/soc
JWT_SECRET_KEY=${JWT_SECRET}

# Wazuh SIEM — uzupełnij po instalacji w panelu Ustawienia
WAZUH_BASE_URL=https://wazuh:55000
WAZUH_USERNAME=wazuh-wui
WAZUH_PASSWORD=
WAZUH_VERIFY_SSL=false
INDEXER_URL=https://wazuh:9200
INDEXER_USERNAME=admin
INDEXER_PASSWORD=
INDEXER_VERIFY_SSL=false

# LLM — uzupełnij klucz API po instalacji
LLM_ENABLED=false
LLM_PROVIDER=openai
LLM_TEMPERATURE=0.2

# Harmonogram
FETCH_INTERVAL_SECONDS=30
AI_INTERVAL_SECONDS=30
CONTEXT_INTERVAL_SECONDS=300
EOF

# ─── Utwórz .env dla dashboardu ───────────────────────────────────────────────
info "Tworzę soc-dashboard/.env ..."
cat > soc-dashboard/.env << EOF
BACKEND_BASE_URL=http://backend:8000
DATABASE_URL=postgresql://soc_user:${DB_PASSWORD}@db:5432/soc
SECRET_KEY=${FLASK_SECRET}
FLASK_SECRET_KEY=${FLASK_SECRET}
EOF

# ─── Utwórz .env główny (dla docker-compose) ──────────────────────────────────
info "Tworzę .env (docker-compose) ..."
cat > .env << EOF
DB_PASSWORD=${DB_PASSWORD}
COMPOSE_PROJECT_NAME=soc
EOF

# Zapisz klucz licencyjny do backendu (jeśli podano)
if [[ -n "${LICENSE_KEY:-}" ]]; then
    echo "" >> backend/.env
    echo "# Licencja (wpisana przy instalacji)" >> backend/.env
    echo "SOC_LICENSE_KEY=${LICENSE_KEY}" >> backend/.env
fi

# ─── Zaktualizuj porty w docker-compose jeśli zmienione ──────────────────────
if [[ "$DASH_PORT" != "5000" || "$API_PORT" != "8000" ]]; then
    sed -i "s/\"5000:5000\"/\"${DASH_PORT}:5000\"/" docker-compose.yml
    # Backend jest bindowany do 127.0.0.1 (bezpieczeństwo) — pasujemy do pełnego wzorca
    sed -i "s/\"127\.0\.0\.1:8000:8000\"/\"127.0.0.1:${API_PORT}:8000\"/" docker-compose.yml
    ok "Porty zaktualizowane: dashboard=$DASH_PORT, API=$API_PORT"
fi

# ─── GeoLite2 (opcjonalne — mapa sieciowa) ────────────────────────────────────
if [[ ! -f "GeoLite2-City.mmdb" ]]; then
    warn "Brak GeoLite2-City.mmdb — mapa live traffic będzie wyłączona."
    warn "Pobierz z: https://www.maxmind.com/en/geolite2/signup"
    warn "i umieść w: ${INSTALL_DIR}/GeoLite2-City.mmdb"
    touch GeoLite2-City.mmdb
fi

# ─── Build i uruchomienie ─────────────────────────────────────────────────────
echo ""
info "Buduję obrazy Docker (może potrwać kilka minut przy pierwszym uruchomieniu)..."
docker compose build --quiet

info "Uruchamiam usługi..."
docker compose up -d

# ─── Czekaj na gotowość backendu ──────────────────────────────────────────────
info "Czekam na uruchomienie backendu (migracje bazy)..."
attempt=0
until curl -sf "http://localhost:${API_PORT}/health" &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge 60 ]]; then
        echo ""
        warn "Backend nie odpowiada po 60s. Sprawdź logi: docker compose logs backend"
        break
    fi
    printf "."
    sleep 2
done
echo ""

# ─── Aktywuj licencję w aplikacji ─────────────────────────────────────────────
if [[ -n "${LICENSE_KEY:-}" ]]; then
    info "Aktywuję licencję w aplikacji..."
    curl -sf -X POST "http://localhost:${API_PORT}/api/license/save" \
        -H "Content-Type: application/json" \
        -d "{\"license_key\": \"${LICENSE_KEY}\"}" &>/dev/null || true
fi

# ─── Podsumowanie ─────────────────────────────────────────────────────────────
APP_VERSION="$(cat VERSION 2>/dev/null || echo "?")"
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   ✅  SOC AI Platform v${APP_VERSION} zainstalowana pomyślnie!  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  🌐  Dashboard:  ${BOLD}http://${HOST}:${DASH_PORT}${NC}"
echo -e "  📡  API health: ${BOLD}http://localhost:${API_PORT}/health${NC}  (tylko localhost)"
echo ""
echo -e "  🔑  Login:      ${BOLD}admin${NC}"
echo -e "  🔑  Hasło:      ${BOLD}Admin123!${NC}"
echo -e "  ${YELLOW}⚠  Zmień hasło natychmiast po pierwszym logowaniu!${NC}"
echo ""
echo -e "  📁  Instalacja: ${INSTALL_DIR}"
echo ""
echo -e "${BOLD}Następne kroki:${NC}"
echo "  1. Zaloguj się i przejdź do Ustawień → System"
echo "  2. Podaj dane Wazuh (URL, login, hasło)"
echo "  3. Opcjonalnie: skonfiguruj LLM (OpenAI/Gemini/Ollama)"
echo "  4. Opcjonalnie: ustaw SMTP do powiadomień email"
echo ""
echo -e "${BOLD}Zarządzanie:${NC}"
echo "  Zatrzymaj:   cd ${INSTALL_DIR} && docker compose down"
echo "  Uruchom:     cd ${INSTALL_DIR} && docker compose up -d"
echo "  Logi:        cd ${INSTALL_DIR} && docker compose logs -f"
echo "  Aktualizuj:  cd ${INSTALL_DIR} && git pull && docker compose up -d --build"
echo ""
