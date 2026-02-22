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

check_git() {
    command -v git 2>&1
}

# Comienzo de la configuración
clear
echo -e "${CYAN}### Iniciando el asistente de configuración para Git en Ubuntu/Debian ###${NC}"
echo

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

# Instalación de Git
if check_git; then
    echo -e "[${GREEN}OK${NC}] Git instalado."
else
    echo -ne "[${YELLOW}INFO${NC}] Instalando Git..."
    apt install git -y 2>&1
    clear_line
    echo -e "[${GREEN}OK${NC}] Git instalado."
fi

# Configuración de Git
current_user=$(git config --global user.name)
if [ -z "$current_user" ]; then
    echo -n "Nombre de usuario global de git: "
    read -r nombre
    git config --global user.name "$nombre"
else
    echo -e "[${GREEN}OK${NC}] Usuario Git actual: $current_user"
fi

current_email=$(git config --global user.email)
if [ -z "$current_email" ]; then
    echo -n "Email de usuario global de git: "
    read -r email
    git config --global user.email "$email"
else
    echo -e "[${GREEN}OK${NC}] Email Git actual: $current_email"
    email=$current_email
fi

if [ ! -f ~/.ssh/id_rsa ]; then
    echo -e "[${YELLOW}INFO${NC}] Generando nueva clave SSH..."
    ssh-keygen -t rsa -b 4096 -C "$email" -f ~/.ssh/id_rsa -N ""
    
    eval "$(ssh-agent -s)" 2>&1
    ssh-add ~/.ssh/id_rsa 2>&1
else
    echo -e "[${GREEN}OK${NC}] Ya existe una clave SSH en ~/.ssh/id_rsa"
fi

echo -e "\nTu clave pública de GitHub es:"
cat ~/.ssh/id_rsa.pub
echo -ne "\nCópiala y añádela a GitHub. Pulsa [Enter] para probar la conexión..."
read -r
echo

# Comprobación de la conexión
ssh_test=$(ssh -T git@github.com 2>&1)
if [[ $ssh_test == *"successfully authenticated"* ]]; then
    echo -e "[${GREEN}OK${NC}] Conexión con GitHub exitosa."
else
    echo -e "[${RED}ERROR${NC}] No se pudo autenticar en GitHub."
    echo -e "Detalle: $ssh_test"
fi
echo

echo -e "${GREEN}### Asistente de configuración para Git en Ubuntu/Debian finalizado ###${NC}"
echo