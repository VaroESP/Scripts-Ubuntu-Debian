
#!/bin/bash
set -Eeuo pipefail

# ============================================================
# COLORES Y FUNCIONES
# ============================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear_line() {
    echo -ne '\r\033[K'
}

error_exit() {
    echo
    echo -e "[${RED}ERROR${NC}] $1"
    if [[ "${CONFIGURATION_COMMITTED:-0}" == "0" ]] && [[ "${KEY_WAS_CREATED:-0}" == "1" || "${REPO_WAS_CREATED:-0}" == "1" ]]; then
        rollback_configuration
    fi
    exit 1
}

# Estado de la transacción de configuración: permite restaurar clave y
# repositorio si falla la validación de APT antes de instalar Docker.
KEY_BACKUP_PATH=""
REPO_BACKUP_PATH=""
KEY_WAS_CREATED=0
REPO_WAS_CREATED=0
CONFIGURATION_COMMITTED=0

rollback_configuration() {
    local failed=0

    if (( CONFIGURATION_COMMITTED == 0 )); then
        if (( REPO_WAS_CREATED == 1 )); then
            if [[ -n "$REPO_BACKUP_PATH" && -f "$REPO_BACKUP_PATH" ]]; then
                cp -a -- "$REPO_BACKUP_PATH" "$DOCKER_REPO_FILE" || failed=1
            else
                rm -f -- "$DOCKER_REPO_FILE" || failed=1
            fi
        fi
        if (( KEY_WAS_CREATED == 1 )); then
            if [[ -n "$KEY_BACKUP_PATH" && -f "$KEY_BACKUP_PATH" ]]; then
                cp -a -- "$KEY_BACKUP_PATH" "$DOCKER_KEY" || failed=1
            else
                rm -f -- "$DOCKER_KEY" || failed=1
            fi
        fi
    fi

    if (( failed == 1 )); then
        echo -e "[${RED}ERROR${NC}] La restauración automática no se completó. Revisa los archivos de configuración y las copias .backup.*."
    fi
}

on_error() {
    local exit_code=$1
    local failed_command=$BASH_COMMAND
    trap - ERR
    echo
    echo -e "[${RED}ERROR${NC}] Error inesperado en la línea ${BASH_LINENO[0]}."
    echo -e "[${RED}ERROR${NC}] Comando: ${failed_command}"
    rollback_configuration
    exit "$exit_code"
}
trap 'on_error $?' ERR

# Registrar temporales para eliminarlos también si se produce un error o
# el usuario interrumpe el script.
TEMP_FILES=()
cleanup() {
    local temp_file
    for temp_file in "${TEMP_FILES[@]:-}"; do
        [[ -n "$temp_file" ]] && rm -f -- "$temp_file"
    done
}
trap cleanup EXIT

register_temp() {
    TEMP_FILES+=("$1")
}

# Genera una copia de seguridad sin sobrescribir otras copias.
backup_file() {
    local source_file="$1"
    local backup_file="${source_file}.backup.$(date +%Y%m%d_%H%M%S)"
    local counter=1

    while [[ -e "$backup_file" ]]; do
        backup_file="${source_file}.backup.$(date +%Y%m%d_%H%M%S)_${counter}"
        ((counter += 1))
    done

    if ! cp -a -- "$source_file" "$backup_file"; then
        error_exit "No se pudo crear la copia de seguridad de $source_file."
    fi

    echo "$backup_file"
}

# ============================================================
# INICIO DEL ASISTENTE
# ============================================================

echo
echo -e "${CYAN}### Iniciando el asistente de configuración para Docker ###${NC}"
echo

# Comprobar permisos de administrador.
if [[ "$EUID" -ne 0 ]]; then
    echo -e "[${YELLOW}INFO${NC}] Ejecuta el script con sudo."
    exit 1
fi

# Comprobar herramientas necesarias.
for command in apt-get dpkg-query dpkg systemctl grep install mktemp awk; do
    if ! command -v "$command" >/dev/null 2>&1; then
        error_exit "No se encuentra el comando necesario: $command"
    fi
done

# ============================================================
# DETECCIÓN DEL SISTEMA OPERATIVO
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    error_exit "No se pudo identificar el sistema operativo."
fi

source /etc/os-release

OS_ID="${ID,,}"
OS_CODENAME="${VERSION_CODENAME:-}"

case "$OS_ID" in
    debian)
        OS_FAMILY="debian"
        REPO_URL="https://download.docker.com/linux/debian"
        REPO_CODENAME="$OS_CODENAME"
        ;;

    ubuntu)
        OS_FAMILY="ubuntu"
        REPO_URL="https://download.docker.com/linux/ubuntu"
        REPO_CODENAME="$OS_CODENAME"
        ;;

    linuxmint)
        OS_FAMILY="ubuntu"
        REPO_URL="https://download.docker.com/linux/ubuntu"
        REPO_CODENAME="${UBUNTU_CODENAME:-}"

        if [[ -z "$REPO_CODENAME" ]]; then
            error_exit "No se pudo identificar la versión de Ubuntu de la que depende Linux Mint."
        fi
        ;;

    *)
        error_exit "Sistema no compatible: ${PRETTY_NAME:-$OS_ID}"
        ;;
esac

if [[ -z "$REPO_CODENAME" ]]; then
    error_exit "No se pudo determinar el nombre en clave de la distribución."
fi

echo -e "[${GREEN}OK${NC}] Sistema detectado: ${PRETTY_NAME:-$OS_ID}"
echo -e "[${GREEN}OK${NC}] Repositorio Docker: $OS_FAMILY ($REPO_CODENAME)"
echo

if [[ "$OS_ID" == "linuxmint" ]]; then
    echo -e "${YELLOW}[AVISO]${NC} Linux Mint utiliza el repositorio de Ubuntu."
    echo -e "${YELLOW}[AVISO]${NC} Docker no ofrece soporte oficial directo para Linux Mint."
    echo
fi

# ============================================================
# COMPROBACIÓN DE INSTALACIONES EXISTENTES
# ============================================================

echo -e "${CYAN}### Comprobando instalaciones existentes ###${NC}"
echo

official_packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

conflicting_packages=(
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
)

installed_official=()
installed_conflicting=()

for pkg in "${official_packages[@]}"; do
    package_status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)

    if [[ "$package_status" == "installed" ]]; then
        installed_official+=("$pkg")
    fi
done

for pkg in "${conflicting_packages[@]}"; do
    package_status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)

    if [[ "$package_status" == "installed" ]]; then
        installed_conflicting+=("$pkg")
    fi
done

# Instalación oficial existente.
if (( ${#installed_official[@]} > 0 )); then
    echo -e "${GREEN}[OK]${NC} Se ha detectado una instalación oficial de Docker:"
    printf '  - %s\n' "${installed_official[@]}"
    echo

    read -r -p "¿Deseas continuar y actualizar Docker? [s/N]: " response

    if [[ ! "$response" =~ ^[sS]$ ]]; then
        echo -e "${YELLOW}[INFO]${NC} Operación cancelada."
        exit 0
    fi
else
    echo -e "${GREEN}[OK]${NC} No se ha detectado una instalación oficial previa."
fi

# Paquetes potencialmente incompatibles.
# No se eliminan automáticamente: containerd/runc pueden ser dependencias
# de otros servicios. Se muestra el plan y se deja la decisión al administrador.
if (( ${#installed_conflicting[@]} > 0 )); then
    echo
    echo -e "${YELLOW}[AVISO]${NC} Se han detectado paquetes que pueden entrar en conflicto:"
    printf '  - %s\n' "${installed_conflicting[@]}"
    echo
    echo -e "${CYAN}### Simulación informativa de la eliminación ###${NC}"
    echo

    if ! removal_plan=$(apt-get -s remove "${installed_conflicting[@]}" 2>&1); then
        echo -e "${RED}[ERROR]${NC} No se pudo simular la eliminación."
        echo "$removal_plan"
        exit 1
    fi

    echo "$removal_plan"
    echo
    echo -e "${YELLOW}[AVISO]${NC} El script no eliminará estos paquetes automáticamente."
    echo -e "${YELLOW}[AVISO]${NC} Revisa si otros servicios dependen de ellos y resuelve el conflicto manualmente."
    echo -e "${YELLOW}[INFO]${NC} Cuando estén resueltos, vuelve a ejecutar este script."
    exit 1
else
    echo -e "${GREEN}[OK]${NC} No se han detectado paquetes incompatibles."
fi

echo

# ============================================================
# COMPROBACIÓN PREVIA DE REPOSITORIOS (SIN MODIFICAR EL SISTEMA)
# ============================================================

DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.sources"
KEYRING_DIR="/etc/apt/keyrings"
DOCKER_KEY="$KEYRING_DIR/docker.asc"

echo -e "${CYAN}### Comprobando repositorios Docker existentes ###${NC}"
echo

declare -a docker_repo_files=()
declare -a repos_to_disable=()

if [[ -f /etc/apt/sources.list ]] && grep -qiF "download.docker.com" /etc/apt/sources.list; then
    error_exit "Se ha encontrado Docker en /etc/apt/sources.list. Revísalo manualmente; no se modificará automáticamente."
fi

# Un archivo deb822 .sources puede contener varios bloques. Solo aceptamos
# docker.sources si todas sus líneas activas forman una única entrada Docker.
if [[ -e "$DOCKER_REPO_FILE" ]]; then
    if [[ ! -f "$DOCKER_REPO_FILE" || -L "$DOCKER_REPO_FILE" ]]; then
        error_exit "$DOCKER_REPO_FILE existe pero no es un archivo regular seguro. No se modificará."
    fi
    active_content=$(grep -Ev '^[[:space:]]*(#|$)' "$DOCKER_REPO_FILE" || true)
    if [[ -z "$active_content" ]] || ! grep -qiF 'download.docker.com' <<< "$active_content"; then
        error_exit "$DOCKER_REPO_FILE ya existe y no es inequívocamente un repositorio Docker. No se sobrescribirá."
    fi
    if grep -Eiq '^[[:space:]]*(Types|URIs|Suites|Components|Architectures|Signed-By|Enabled):' "$DOCKER_REPO_FILE"; then
        uri_count=$(grep -Eic '^[[:space:]]*URIs:[[:space:]]*https?://download\.docker\.com/linux/(debian|ubuntu)[[:space:]]*$' "$DOCKER_REPO_FILE" || true)
        other_uri_count=$(grep -Eic '^[[:space:]]*URIs:' "$DOCKER_REPO_FILE" || true)
        stanza_count=$(grep -Eic '^[[:space:]]*Types:' "$DOCKER_REPO_FILE" || true)
        suites_count=$(grep -Eic '^[[:space:]]*Suites:' "$DOCKER_REPO_FILE" || true)
        if [[ "$uri_count" -ne 1 || "$other_uri_count" -ne 1 || "$stanza_count" -ne 1 || "$suites_count" -ne 1 ]]; then
            error_exit "$DOCKER_REPO_FILE contiene múltiples bloques, URIs o campos inesperados. Revísalo manualmente; no se sobrescribirá."
        fi
    else
        error_exit "$DOCKER_REPO_FILE no tiene formato deb822 reconocible. No se sobrescribirá."
    fi
    docker_repo_files+=("$DOCKER_REPO_FILE")
fi

for repo_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$repo_file" ]] || continue
    [[ "$repo_file" == "$DOCKER_REPO_FILE" ]] && continue
    if grep -qiF "download.docker.com" "$repo_file"; then
        docker_repo_files+=("$repo_file")
        if [[ "$repo_file" == *.sources ]]; then
            error_exit "Se ha encontrado un archivo .sources adicional con Docker: $repo_file. Revísalo manualmente; no se modificará."
        fi
        other_entries=$(grep -Ev '^[[:space:]]*(#|$)' "$repo_file" | grep -viF 'download.docker.com' || true)
        if [[ -n "$other_entries" ]]; then
            error_exit "El archivo $repo_file mezcla Docker con otros repositorios. No se modificará."
        fi
        error_exit "Se ha encontrado otro archivo .list de Docker: $repo_file. Para evitar duplicados o cambios ajenos, revísalo y retíralo manualmente antes de continuar."
    fi
done

if (( ${#docker_repo_files[@]} > 0 )); then
    echo -e "${YELLOW}[INFO]${NC} Repositorios Docker existentes:"
    printf '  - %s\n' "${docker_repo_files[@]}"
    echo -e "${YELLOW}[AVISO]${NC} Se crearán copias de seguridad antes de sustituir o retirar entradas Docker."
else
    echo -e "${GREEN}[OK]${NC} No se han detectado repositorios Docker previos."
fi

echo
read -r -p "¿Deseas continuar con las comprobaciones y la configuración? [s/N]: " response
if [[ ! "$response" =~ ^[sS]$ ]]; then
    echo -e "${YELLOW}[INFO]${NC} Operación cancelada. No se han realizado cambios."
    exit 0
fi

# Comprobar utilidades necesarias antes de tocar el sistema.
# Las herramientas de descarga y validación se instalarán solo después de
# completar todas las comprobaciones previas y de mostrar el plan de APT.

# ============================================================
# INSTALACIÓN CONTROLADA DE DEPENDENCIAS
# ============================================================

echo -e "${CYAN}### Preparando dependencias necesarias ###${NC}"
if ! apt-get update -qq; then
    error_exit "No se pudo actualizar APT usando los repositorios actuales. No se ha cambiado la configuración de Docker."
fi
DEPENDENCIES=(ca-certificates curl gnupg)
if ! dependency_plan=$(apt-get -s install "${DEPENDENCIES[@]}" 2>&1); then
    echo "$dependency_plan"
    error_exit "No se pudo simular la instalación de las dependencias necesarias."
fi
echo "$dependency_plan"
if grep -Eq '^(Remv|Removals:)' <<< "$dependency_plan"; then
    error_exit "La instalación de dependencias eliminaría paquetes. Resuelve el conflicto manualmente antes de continuar."
fi
read -r -p "¿Apruebas la instalación de estas dependencias? [s/N]: " response
if [[ ! "$response" =~ ^[sS]$ ]]; then
    error_exit "Operación cancelada antes de modificar el sistema."
fi
if ! apt-get install -y "${DEPENDENCIES[@]}"; then
    error_exit "No se pudieron instalar las dependencias necesarias."
fi
for command in curl gpg; do
    command -v "$command" >/dev/null 2>&1 || error_exit "No se encuentra el comando necesario tras instalar dependencias: $command"
done

# ============================================================
# DESCARGA Y VALIDACIÓN DE LA CLAVE GPG (SIN INSTALARLA AÚN)
# ============================================================

echo -ne "[${YELLOW}INFO${NC}] Descargando y validando la clave GPG oficial de Docker..."
KEY_TEMP=$(mktemp)
register_temp "$KEY_TEMP"
if ! curl -fsSL "${REPO_URL}/gpg" -o "$KEY_TEMP"; then
    clear_line
    error_exit "No se pudo descargar la clave GPG."
fi

if [[ ! -s "$KEY_TEMP" ]] || ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$KEY_TEMP"; then
    clear_line
    error_exit "La descarga no contiene un bloque de clave pública PGP válido."
fi
if ! gpg --batch --show-keys "$KEY_TEMP" >/dev/null 2>&1; then
    clear_line
    error_exit "GPG no reconoce el contenido descargado como una clave pública válida."
fi

# La clave se valida estructuralmente con GPG y se instalará con permisos
# restrictivos. La autenticidad del origen se apoya en HTTPS de Docker;
# APT verificará después las firmas del repositorio.
clear_line
echo -e "[${GREEN}OK${NC}] Clave descargada y reconocida por GPG."
echo

# ============================================================
# PREPARACIÓN DE DEPENDENCIAS Y CAMBIOS
# ============================================================

# No se ejecuta apt-get update/install de dependencias antes de completar
# las comprobaciones de repositorio y clave. Si faltan curl/gpg, se detiene
# sin instalar paquetes de forma implícita.

# ============================================================
# CONFIGURACIÓN DEL REPOSITORIO OFICIAL
# ============================================================

ARCHITECTURE=$(dpkg --print-architecture)
REPO_TEMP=$(mktemp "${DOCKER_REPO_FILE}.XXXXXX")
register_temp "$REPO_TEMP"
KEY_INSTALL_TEMP=$(mktemp "${DOCKER_KEY}.XXXXXX")
register_temp "$KEY_INSTALL_TEMP"

cat > "$REPO_TEMP" <<EOF
Types: deb
URIs: ${REPO_URL}
Suites: ${REPO_CODENAME}
Components: stable
Architectures: ${ARCHITECTURE}
Signed-By: ${DOCKER_KEY}
EOF

install -m 0644 "$KEY_TEMP" "$KEY_INSTALL_TEMP"

# Guardar copias antes de modificar cualquiera de los dos archivos.
if [[ -e "$DOCKER_KEY" ]]; then
    KEY_BACKUP_PATH=$(backup_file "$DOCKER_KEY")
fi
KEY_WAS_CREATED=1
if [[ -e "$DOCKER_REPO_FILE" ]]; then
    REPO_BACKUP_PATH=$(backup_file "$DOCKER_REPO_FILE")
fi
REPO_WAS_CREATED=1

install -m 0644 "$KEY_INSTALL_TEMP" "$DOCKER_KEY"
install -m 0644 "$REPO_TEMP" "$DOCKER_REPO_FILE"

clear_line
echo -e "[${GREEN}OK${NC}] Clave y repositorio oficial configurados con copias de seguridad."
echo

# ============================================================
# ACTUALIZACIÓN DE LA LISTA DE PAQUETES
# ============================================================

echo -ne "[${YELLOW}INFO${NC}] Actualizando lista de paquetes..."

if ! apt-get update; then
    clear_line
    rollback_configuration
    CONFIGURATION_COMMITTED=1
    error_exit "No se pudo actualizar la lista de paquetes. Se ha intentado restaurar la clave y el repositorio anteriores."
fi

clear_line
echo -e "[${GREEN}OK${NC}] Lista de paquetes actualizada y firmas del repositorio verificadas por APT."
CONFIGURATION_COMMITTED=1
echo

# ============================================================
# INSTALACIÓN O ACTUALIZACIÓN DE DOCKER
# ============================================================

DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

echo -e "${CYAN}### Simulando la instalación o actualización de Docker ###${NC}"
echo

if ! install_plan=$(apt-get -s install "${DOCKER_PACKAGES[@]}" 2>&1); then
    echo -e "${RED}[ERROR]${NC} No se pudo simular la instalación de Docker."
    echo "$install_plan"
    error_exit "Revisa los repositorios y las dependencias antes de continuar."
fi

echo "$install_plan"
echo
if grep -Eq '^(Remv|Removals:)' <<< "$install_plan"; then
    echo -e "${RED}[AVISO]${NC} La simulación contempla la eliminación de paquetes."
    echo -e "${RED}[AVISO]${NC} No se continuará automáticamente: revisa las dependencias y resuelve el conflicto manualmente."
    exit 1
fi
read -r -p "¿Apruebas este plan de instalación/actualización? [s/N]: " response

if [[ ! "$response" =~ ^[sS]$ ]]; then
    echo -e "${YELLOW}[INFO]${NC} Instalación cancelada. Se conserva la configuración del repositorio."
    exit 0
fi

echo -ne "[${YELLOW}INFO${NC}] Instalando o actualizando los componentes de Docker..."

if ! apt-get install -y "${DOCKER_PACKAGES[@]}"; then
    clear_line
    error_exit "No se pudieron instalar o actualizar los componentes de Docker."
fi

clear_line
echo -e "[${GREEN}OK${NC}] Componentes de Docker instalados o actualizados."
echo

# ============================================================
# ACTIVACIÓN DEL SERVICIO DOCKER
# ============================================================

echo -ne "[${YELLOW}INFO${NC}] Habilitando e iniciando el servicio Docker..."

if ! systemctl enable --now docker; then
    clear_line
    echo -e "${RED}[ERROR]${NC} No se pudo iniciar el servicio Docker."
    systemctl status docker --no-pager || true
    exit 1
fi

clear_line
echo -e "[${GREEN}OK${NC}] Servicio Docker iniciado y habilitado."
echo

# ============================================================
# COMPROBACIÓN DEL SERVICIO
# ============================================================

if ! systemctl is-active --quiet docker; then
    echo -e "${RED}[ERROR]${NC} Docker no está activo."
    systemctl status docker --no-pager || true
    exit 1
fi

echo -e "[${GREEN}OK${NC}] Docker está funcionando."
echo

# ============================================================
# VERSIONES INSTALADAS
# ============================================================

echo -e "${CYAN}### Versiones instaladas ###${NC}"
echo

docker --version
docker compose version
echo

# ============================================================
# PRUEBA FUNCIONAL
# ============================================================

echo -e "${CYAN}### Prueba funcional de Docker ###${NC}"
echo

echo -e "${YELLOW}[INFO]${NC} La prueba puede descargar la imagen hello-world de Internet."
echo

read -r -p "¿Deseas ejecutar la prueba funcional? [s/N]: " response

if [[ "$response" =~ ^[sS]$ ]]; then
    if ! docker run --rm hello-world; then
        error_exit "La prueba funcional de Docker no se ha completado correctamente."
    fi

    echo
    echo -e "[${GREEN}OK${NC}] Docker ha ejecutado correctamente un contenedor."
else
    echo -e "${YELLOW}[INFO]${NC} Prueba funcional omitida."
fi

echo

# ============================================================
# INFORMACIÓN PARA UTILIZAR DOCKER SIN SUDO
# ============================================================

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo -e "${CYAN}### Uso de Docker sin sudo ###${NC}"
    echo
    echo "Para permitir que ${SUDO_USER} utilice Docker sin sudo, ejecuta:"
    echo
    echo "  sudo usermod -aG docker ${SUDO_USER}"
    echo
    echo "Después tendrás que cerrar sesión y volver a entrar."
    echo
    echo -e "${YELLOW}[AVISO]${NC} El grupo docker concede privilegios equivalentes a root."
else
    echo -e "${YELLOW}[INFO]${NC} Puedes configurar el grupo docker manualmente si lo necesitas."
fi

# ============================================================
# FINALIZACIÓN
# ============================================================

echo
echo -e "${CYAN}### Asistente de configuración para Docker finalizado ###${NC}"
echo
