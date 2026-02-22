#!/bin/bash

# Colores
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Funciones
clear_line(){
    echo -ne '\r\033[K'
}

check_tree() {
    command -v tree 2>&1
}

# Comienzo de la configuración
echo
echo -e "${CYAN}### Iniciando el asistente de configuración para Tree en Ubuntu/Debian ###${NC}\n"

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

# Configuración de Tree
if check_tree; then
    echo -e "[${GREEN}OK${NC}] Tree instalado."
else
    echo -ne "[${YELLOW}INFO${NC}] Instalando Tree..."
    apt install tree -y 2>&1
    clear_line
    echo -e "[${GREEN}OK${NC}] Tree instalado."
fi
echo

echo -e "${CYAN}### Asistente de configuración para Tree en Ubuntu/Debian finalizado ###${NC}"
echo