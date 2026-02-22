#!/bin/bash

# Colores
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear_line(){
    echo -ne '\r\033[K'
}

# Comienzo de la configuración
echo
echo -e "${CYAN}### Iniciando el asistente de configuración para Docker en Ubuntu/Debian ###${NC}\n"

# Permisos de administrador
if [ "$EUID" -ne 0 ]; then 
  echo -e "[${YELLOW}INFO${NC}] No tiene permisos de administrador. Por favor, ejecuta el script con sudo."
  exit
fi

#Sistema operativo correcto
if [ -f /etc/os-release ]; then
    # Extraemos el nombre de la distribución
    os_name=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
    os_base=$(grep ^ID_LIKE= /etc/os-release | cut -d= -f2 | tr -d '"')

    if [[ "$os_name" != "linuxmint" && "$os_name" != "ubuntu" && "$os_base" != *"ubuntu"* && "$os_base" != *"debian"* ]]; then
        echo -e "[${RED}ERROR${NC}] Este script está diseñado para Linux Mint/Ubuntu/Debian."
        echo -e "[${YELLOW}INFO${NC}] Tu sistema detectado es: ${os_name}"
        exit
    else
        echo -e "[${GREEN}OK${NC}] Sistema compatible detectado: ${os_name}"
    fi
else
    echo -e "[${RED}ERROR${NC}] No se pudo identificar el sistema operativo."
    echo
    exit
fi

# Configuración de Docker

echo -ne "[${YELLOW}INFO${NC}] Quitando versiones anteriores..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
	apt remove -y $pkg > /dev/null 2>&1
done
clear_line
echo -e "[${GREEN}OK${NC}] Versiones anteriores eliminadas."
echo

echo -ne "[${YELLOW}INFO${NC}] Actualizando lista de paquetes y dependencias..."
apt update > /dev/null 2>&1
install -y ca-certificates curl > /dev/null 2>&1
clear_line
echo -e "[${GREEN}OK${NC}] Lista de paquetes y dependencias actualizadas."
echo

echo -ne "[${YELLOW}INFO${NC}] Configurando el directorio GPG..."
install -m 0755 -d /etc/apt/keyrings > /dev/null 2>&1
clear_line
echo -e "[${GREEN}OK${NC}] Directorio GPG configurado."
echo

echo -ne "[${YELLOW}INFO${NC}] Descargando la llave GPG oficial de docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc > /dev/null 2>&1
chmod a+r /etc/apt/keyrings/docker.asc > /dev/null 2>&1
clear_line
echo -e "[${GREEN}OK${NC}] Llave GPG descargada."
echo

echo -ne "[${YELLOW}INFO${NC}] Añadiendo el repositorio oficial de docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
clear_line
echo -e "[${GREEN}OK${NC}] Repositorio oficial de docker añadido."
echo

echo -ne "[${YELLOW}INFO${NC}] Actualizando..."
apt update > /dev/null 2>&1
clear_line
echo -e "[${GREEN}OK${NC}] Actualizado"
echo

echo -ne "[${YELLOW}INFO${NC}] Instalando componentes de docker..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
clear_line
echo -e "[${GREEN}OK${NC}] Componentes de docker instalados."
echo

echo "Comprobando el estado del servicio de docker..."
systemctl status docker --no-pager
echo

echo "Para usar Docker sin <sudo>, únete al grupo de docker."
echo "	- sudo usermod -aG docker \$USER"
echo "Debe reiniciar para ver estos cambios reflejados."
echo
echo -e "${CYAN}### Asistente de configuración para Docker en Ubuntu/Debian finalizado ###${NC}"
echo
