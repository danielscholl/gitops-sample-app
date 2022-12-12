#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/azcli.md
# Maintainer: The VS Code and Codespaces Teams
#
# Syntax: ./azcli-debian.sh

set -e

AZ_VERSION=${1:-"latest"}
MICROSOFT_GPG_KEYS_URI="https://packages.microsoft.com/keys/microsoft.asc"
AZCLI_ARCHIVE_ARCHITECTURES="amd64"
AZCLI_ARCHIVE_VERSION_CODENAMES="stretch buster bullseye bionic focal jammy"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Get central common setting
get_common_setting() {
    if [ "${common_settings_file_loaded}" != "true" ]; then
        curl -sfL "https://aka.ms/vscode-dev-containers/script-library/settings.env" 2>/dev/null -o /tmp/vsdc-settings.env || echo "Could not download settings file. Skipping."
        common_settings_file_loaded=true
    fi
    if [ -f "/tmp/vsdc-settings.env" ]; then
        local multi_line=""
        if [ "$2" = "true" ]; then multi_line="-z"; fi
        local result="$(grep ${multi_line} -oP "$1=\"?\K[^\"]+" /tmp/vsdc-settings.env | tr -d '\0')"
        if [ ! -z "${result}" ]; then declare -g $1="${result}"; fi
    fi
    echo "$1=${!1}"
}

# Function to run apt-get if needed
apt_get_update_if_needed()
{
    if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update
    else
        echo "Skipping apt-get update."
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update_if_needed
        apt-get -y install --no-install-recommends "$@"
    fi
}

export DEBIAN_FRONTEND=noninteractive

# Soft version matching that resolves a version for a given package in the *current apt-cache*
# Return value is stored in first argument (the unprocessed version)
apt_cache_version_soft_match() {

    # Version
    local variable_name="$1"
    local requested_version=${!variable_name}
    # Package Name
    local package_name="$2"
    # Exit on no match?
    local exit_on_no_match="${3:-true}"

    # Ensure we've exported useful variables
    . /etc/os-release
    local architecture="$(dpkg --print-architecture)"

    dot_escaped="${requested_version//./\\.}"
    dot_plus_escaped="${dot_escaped//+/\\+}"
    # Regex needs to handle debian package version number format: https://www.systutorials.com/docs/linux/man/5-deb-version/
    version_regex="^(.+:)?${dot_plus_escaped}([\\.\\+ ~:-]|$)"
    set +e # Don't exit if finding version fails - handle gracefully
        fuzzy_version="$(apt-cache madison ${package_name} | awk -F"|" '{print $2}' | sed -e 's/^[ \t]*//' | grep -E -m 1 "${version_regex}")"
    set -e
    if [ -z "${fuzzy_version}" ]; then
        echo "(!) No full or partial for package \"${package_name}\" match found in apt-cache for \"${requested_version}\" on OS ${ID} ${VERSION_CODENAME} (${architecture})."

        if $exit_on_no_match; then
            echo "Available versions:"
            apt-cache madison ${package_name} | awk -F"|" '{print $2}' | grep -oP '^(.+:)?\K.+'
            exit 1 # Fail entire script
        else
            echo "Continuing to fallback method (if available)"
            return 1;
        fi
    fi

    # Globally assign fuzzy_version to this value
    # Use this value as the return value of this function
    declare -g ${variable_name}="=${fuzzy_version}"
    echo "${variable_name} ${!variable_name}"
}

install_using_apt() {
    # Install dependencies
    check_packages apt-transport-https curl ca-certificates gnupg2 dirmngr
    # Import key safely (new 'signed-by' method rather than deprecated apt-key approach) and install
    get_common_setting MICROSOFT_GPG_KEYS_URI
    curl -sSL ${MICROSOFT_GPG_KEYS_URI} | gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg
    echo "deb [arch=${architecture} signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/azure-cli/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/azure-cli.list
    apt-get update

    if [ "${AZ_VERSION}" = "latest" ] || [ "${AZ_VERSION}" = "lts" ] || [ "${AZ_VERSION}" = "stable" ]; then
        # Empty, meaning grab the "latest" in the apt repo
        AZ_VERSION=""
    else
        # Sets AZ_VERSION to our desired version, if match found.
        apt_cache_version_soft_match AZ_VERSION "azure-cli" false
        if [ "$?" != 0 ]; then
            return 1
        fi
    fi

    if ! (apt-get install -yq azure-cli${AZ_VERSION}); then
        rm -f /etc/apt/sources.list.d/azure-cli.list
        return 1
    fi
}

install_using_pip() {
    echo "(*) No pre-built binaries available in apt-cache. Installing via pip3."
    if ! dpkg -s python3-minimal python3-pip libffi-dev python3-venv > /dev/null 2>&1; then
        apt_get_update_if_needed
        apt-get -y install python3-minimal python3-pip libffi-dev python3-venv
    fi
    export PIPX_HOME=/usr/local/pipx
    mkdir -p ${PIPX_HOME}
    export PIPX_BIN_DIR=/usr/local/bin
    export PYTHONUSERBASE=/tmp/pip-tmp
    export PIP_CACHE_DIR=/tmp/pip-tmp/cache
    pipx_bin=pipx
    if ! type pipx > /dev/null 2>&1; then
        pip3 install --disable-pip-version-check --no-cache-dir --user pipx
        pipx_bin=/tmp/pip-tmp/bin/pipx
    fi

    if [ "${AZ_VERSION}" = "latest" ] || [ "${AZ_VERSION}" = "lts" ] || [ "${AZ_VERSION}" = "stable" ]; then
        # Empty, meaning grab the "latest" in the apt repo
        ver=""
    else
        ver="==${AZ_VERSION}"
    fi

    set +e
        ${pipx_bin} install --pip-args '--no-cache-dir --force-reinstall' -f azure-cli${ver}

        # Fail gracefully
        if [ "$?" != 0 ]; then
            echo "Could not install azure-cli${ver} via pip"
            rm -rf /tmp/pip-tmp
            return 1
        fi
    set -e
}

# See if we're on x86_64 and if so, install via apt-get, otherwise use pip3
echo "(*) Installing Azure CLI..."
. /etc/os-release
architecture="$(dpkg --print-architecture)"
CACHED_AZURE_VERSION="${AZ_VERSION}" # In case we need to fallback to pip and the apt path has modified the AZ_VERSION variable.
if [[ "${AZCLI_ARCHIVE_ARCHITECTURES}" = *"${architecture}"* ]] && [[  "${AZCLI_ARCHIVE_VERSION_CODENAMES}" = *"${VERSION_CODENAME}"* ]]; then
    install_using_apt || use_pip="true"
else
    use_pip="true"
fi

if [ "${use_pip}" = "true" ]; then
    AZ_VERSION=${CACHED_AZURE_VERSION}
    install_using_pip

    if [ "$?" != 0 ]; then
        echo "Please provide a valid version for your distribution ${ID} ${VERSION_CODENAME} (${architecture})."
        echo
        echo "Valid versions in current apt-cache"
        apt-cache madison azure-cli | awk -F"|" '{print $2}' | grep -oP '^(.+:)?\K.+'
        exit 1
    fi
fi

HELM_VERSION=${1:-"v3.10.0"}
echo "================================================================================="
echo "Installing helm command."
wget -q https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz -O helm-$HELM_VERSION-linux-amd64.tar.gz
tar -zxvf helm-$HELM_VERSION-linux-amd64.tar.gz -C /usr/local/bin --strip-components=1 linux-amd64/helm
echo "The helm command line tool is installed... Done."

echo "================================================================================"
echo "Installing flux command."
curl -s https://fluxcd.io/install.sh | bash;
echo "The flux command line tool is installed... Done."

YQ_VERSION="4.30.5"
echo "================================================================================="
echo "Installing yq command."
curl -sL https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
echo "The yq command line tool is installed... Done."


KUSTOMIZE_VERSION="4.5.7"
echo "================================================================================="
echo "Installing kustomize command."
kustomize_url=https://github.com/kubernetes-sigs/kustomize/releases/download && \
wget -q  ${kustomize_url}/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz  -O kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
tar -zxvf kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz -C /usr/local/bin
echo "The kustomize command line tool is installed... Done."


KUBECONFORM_VERSION="0.5.0"
echo "================================================================================="
echo "Installing kubeconform command."
kubeconform_url=https://github.com/yannh/kubeconform/releases/download && \
wget -q  ${kubeconform_url}/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz  -O kubeconform_v${KUBECONFORM_VERSION}_linux_amd64.tar.gz
tar -zxvf kubeconform_v${KUBECONFORM_VERSION}_linux_amd64.tar.gz -C /usr/local/bin kubeconform
echo "The kubeconform command line tool is installed... Done."

echo "================================================================================="
echo "Installing kubectl command."
az aks install-cli
echo "Done!"
