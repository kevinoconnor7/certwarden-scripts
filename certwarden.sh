#!/bin/bash

set -eu

# Default values
server=""
cert_name=""
cert_api_key=""
cert_file=""
key_api_key=""
key_file=""
uid=$(id -u)
gid=$(id -g)
mode="0600"
postprocess_hook="$(dirname $0)/postprocess.sh"

# Function to display script usage
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo " --cert-api-key  The API key to use to download the certificate"
  echo " --cert-file     The file path to install the certificate to"
  echo " --cert-name     The name of the certificate to download"
  echo " -g, --gid       The group id to install the certificate and private key with Default: id -g"
  echo " -h, --help      Display this help message"
  echo " --key-api-key   The API key to use to download the private key"
  echo " --key-file      The file path to install the private key to"
  echo " -m, --mode      The file mode install the certificate and private key with. Default: 0600"
  echo " --postprocess   The path to an executable to run after the certificate and private key are installed."
  echo "                 The installed certificate and private key are passed as arguments."
  echo "                 Default: postprocess.sh"
  echo " -s, --server    The server to download the certificate and private key from. "
  echo "                 Ex. https://certwarden.example.com"
  echo " -u, --uid       The user id to install the certificate and private key with. Default: id -u"
  echo ""
  echo "Exit codes:"
  echo " 0  Success  A new certificate was downloaded and replaced the existing one"
  echo " 1  Error    General error"
  echo " 2  Error    Certificate did not need to be updated"
}

color() {
  local -r color_name="$1"
  local -r message="$2"

  local code="0;37"
  case "${color_name}" in
    red     ) code='0;31' ;;
    green   ) code='0;32' ;;
    yellow  ) code='0;33' ;;
    *       ) code='0;37' ;;
  esac

  printf "\e[%sm%s\e[0m\n" "${code}" "${message}"
}

print_error() {
  echo "$(color red '[ERROR]') $1"
}

print_success() {
  echo "$(color green '[SUCCESS]') $1"
}

die() {
  exit "${1:-1}"
}

die_with_usage() {
  usage
  exit "${1:-1}"
}

has_argument() {
    [[ ("$1" == *=* && -n ${1#*=}) || ( ! -z "$2" && "$2" != -*)  ]];
}

extract_argument() {
  echo "${2:-${1#*=}}"
}

# Function to handle options and arguments
handle_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help)
        die_with_usage 0
        ;;
      --cert-name*)
        if ! has_argument $@; then
          print_error "Certificate name not specified." >&2
          die_with_usage
        fi

        cert_name=$(extract_argument $@)

        shift
        ;;
      --cert-api-key*)
        if ! has_argument $@; then
          print_error "Certificate API key not specified." >&2
          die_with_usage
        fi

        cert_api_key=$(extract_argument $@)

        shift
        ;;
      --key-api-key*)
        if ! has_argument $@; then
          print_error "Private key API key not specified." >&2
          die_with_usage
        fi

        key_api_key=$(extract_argument $@)

        shift
        ;;
      --cert-file*)
        if ! has_argument $@; then
          print_error "Certificate file not specified." >&2
          die_with_usage
        fi

        cert_file=$(extract_argument $@)

        shift
        ;;
      --key-file*)
        if ! has_argument $@; then
          print_error "Private key file not specified." >&2
          die_with_usage
        fi

        key_file=$(extract_argument $@)

        shift
        ;;
      -s | --server*)
        if ! has_argument $@; then
          print_error "Server not specified." >&2
          die_with_usage
        fi

        server=$(extract_argument $@)

        shift
        ;;
      -u | --uid*)
        if ! has_argument $@; then
          print_error "user id not specified." >&2
          die_with_usage
        fi

        uid=$(extract_argument $@)

        shift
        ;;
      -g | --gid*)
        if ! has_argument $@; then
          print_error "group id not specified." >&2
          die_with_usage
        fi

        gid=$(extract_argument $@)

        shift
        ;;
      -m | --mode*)
        if ! has_argument $@; then
          print_error "file mode not specified." >&2
          die_with_usage
        fi

        mode=$(extract_argument $@)

        shift
        ;;
      --postprocess*)
        if ! has_argument $@; then
          print_error "postprocess script not specified." >&2
          die_with_usage
        fi

        postprocess_hook=$(extract_argument $@)

        if [[ ! -f "${postprocess_hook}" ]]; then
          print_error "Postprocess script does not exist." >&2
          die_with_usage
        fi

        shift
        ;;
      *)
        print_error "Invalid option: $1" >&2
        die_with_usage
        ;;
    esac
    shift
  done
}

check_var_defined() {
  local -r flag_name=$1
  local -r value=$2
  if [[ -z "${value}" ]]; then
    print_error "--${flag_name} is not defined"
    die_with_usage
  fi
}

download_to_file() {
  local -r url="$1"
  local -r apikey="$2"
  local -r file="$3"

  status_code=$(curl -L -o "${file}" --header "X-API-Key: ${apikey}" -w "%{http_code}" "${url}" 2>/dev/null)
  if [[ "${status_code}" -ne 200 ]]; then
    print_error "Failed to download file from ${url} with HTTP status: ${status_code}."
    die
  fi
}

# Check that curl is installed.
if ! command -v curl &> /dev/null; then
  print_error "curl is not installed."
  die
fi

# Main script execution
handle_options "$@"

# Check required parameters are set.
check_var_defined "cert-name" "${cert_name}"
check_var_defined "cert-api-key" "${cert_api_key}"
check_var_defined "key-api-key" "${key_api_key}"
check_var_defined "cert-file" "${cert_file}"
check_var_defined "key-file" "${key_file}"
check_var_defined "key-file" "${key_file}"
check_var_defined "server" "${server}"
check_var_defined "gid" "${gid}"
check_var_defined "uid" "${uid}"
check_var_defined "mode" "${mode}"
check_var_defined "postprocess" "${postprocess_hook}"

# Force https if not specified
if [[ ! "${server}" =~ ^http(s)?:// ]]; then
  server="https://${server}"
fi


# Create a temporary directory to work in, and clean it up when we exit.
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

# Download the certificate and private key
cert_url="${server}/certwarden/api/v1/download/certificates/${cert_name}"
key_url="${server}/certwarden/api/v1/download/privatekeys/${cert_name}"
tmp_cert_file="${tmp_dir}/cert.pem"
tmp_key_file="${tmp_dir}/cert.key"

download_to_file "${cert_url}" "${cert_api_key}" "${tmp_cert_file}"
download_to_file "${key_url}" "${key_api_key}" "${tmp_key_file}"

# Check if the certificate needs to be updated, if not exit early.
updated_file=0

if ! diff -s "${cert_file}" "${tmp_cert_file}" &> /dev/null; then
  install -m "${mode}" -o "${uid}" -g "${gid}" "${tmp_cert_file}" "${cert_file}"
  updated_file=1
fi

if ! diff -s "${key_file}" "${tmp_key_file}" &> /dev/null; then
  install -m "${mode}" -o "${uid}" -g "${gid}" "${tmp_key_file}" "${key_file}"
  updated_file=1
fi

# If nothing was updated exit with a special code.
if [[ "${updated_file}" -eq 0 ]]; then
  print_success "Certificate/key did not need to be updated."
  die 2
fi

print_success "Certificate/key updated successfully."

# Run the postprocess hook if it exists.
if [[ -f "${postprocess_hook}" ]]; then
  echo "Running postprocess hook..."
  if [[ ! -x  "${postprocess_hook}" ]]; then
    print_error "Postprocess hook is not executable."
    die 1
  fi
  "${postprocess_hook}" "${cert_file}" "${key_file}"
  print_success "Postprocess hook ran successfully."
fi

exit 0
