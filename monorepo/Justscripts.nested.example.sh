#!/usr/bin/env sh
# shellcheck disable=SC2015
# shellcheck disable=SC2120

# Source the common library using relative path
PROJECT_NAME="example"
export PROJECT_NAME
PROJECT_DIR="$(pwd)"
. "$PROJECT_DIR/../Justscripts.common.sh"

init_project () {
    create_shared_network "trader"
    create_default_directories_and_files
    create_or_update_dotenv
    build_base_image
    start_base_container_and_apply_migrations
}

start_project () {
    echo_title "Starting all project services"
    docker compose -f docker-compose.yaml up example_start -d
}

stop_project () {
    echo_title "Stoping all project services"
    docker compose -f docker-compose.yaml down
}

refresh_project () {
    stop_base_container_if_running
    create_or_update_dotenv
    build_base_image
    start_project
    start_base_container_and_apply_migrations
}

# shellcheck disable=SC2120
build_base_image () {
  FORCE_FLAG="{$1}"
  [ "${FORCE_FLAG}" = "--force" ] && rm -rdf poetry.lock
  stop_base_container_if_running
  echo_title "Building example base image"
  IMAGE_VERSION="$(image_version)"
  docker compose -f docker-compose.yaml build --build-arg IMAGE_VERSION="${IMAGE_VERSION}" example_image
  copy_poetry_lock_file_from_data_provider_image_if_it_does_not_exist
}

setup_tests () {
  setup_db_for_tests "test_example_db" ${TEST_EXAMPLE_DATABASE_CONNECTION_STRING}
}

test_code () {
    TEST_PATH="${1:-./tests}"
    OPTS="${2}"
    test_python_code "${TEST_PATH}" "${TEST_EXAMPLE_DATABASE_CONNECTION_STRING}" "${OPTS}"
}

check_code () {
    check_python_code
}

format_code () {
  TARGET="${1:-./}"
  IGNORE="${2}"
  format_python_code "${TARGET}" "${IGNORE}"
}

create_or_update_dotenv () {
  REAL_DOTENV_TEMPLATE_MD5="$(md5sum .env.template | cut -d ' ' -f1 | cut -c -8)"
  SAVED_DOTENV_TEMPLATE_MD5=""
  [ -f .env ] && SAVED_DOTENV_TEMPLATE_MD5="$(grep -m 1 -e "^DOTENV_TEMPLATE_MD5=" .env | cut -d '=' -f2)"
  if [ "${REAL_DOTENV_TEMPLATE_MD5}" = "${SAVED_DOTENV_TEMPLATE_MD5}" ]
  then
    echo_title "Updating .env file"
    echo_default "The .env ile is up to date. Skipping."
  fi

  if [ ! -f .env ]
  then
    echo_title "Creating .env file"
    echo_default "Creating new .env file from .env.template file"
    cp .env.template .env
    store_variable_in_dotenv_file STORAGE_ABSOLUTE_HOST_PATH "$(pwd)/_storage"
    connection_string=$(get_database_connection_string \
      "$(cat $(pwd)/.secret/db_user)" \
      "$(cat $(pwd)/.secret/db_user_password)" \
      "$(get_variable_from_dotenv_file DB_HOST)" \
      "$(cat $(pwd)/.secret/db_name)")
    store_variable_in_dotenv_file EXAMPLE_DATABASE_CONNECTION_STRING "${connection_string}"
    test_connection_string=$(get_database_connection_string \
      "test" \
      "test" \
      "$(get_variable_from_dotenv_file DB_HOST)" \
      "test_$(cat $(pwd)/.secret/db_name)")
    store_variable_in_dotenv_file TEST_EXAMPLE_DATABASE_CONNECTION_STRING "${test_connection_string}"
  else
    echo_title "Updatind .env file"
    rm -f .local/.env.backup && cp .env .local/.env.backup && rm -f .env && cp .env.template .env
    restore_variable_in_dotenv_file EXAMPLE_DATABASE_CONNECTION_STRING
    restore_variable_in_dotenv_file TEST_EXAMPLE_DATABASE_CONNECTION_STRING
    restore_variable_in_dotenv_file STORAGE_ABSOLUTE_HOST_PATH
  fi
  echo_default "Storing .env.template md5 sum."
  sed_inplace "s|^DOTENV_TEMPLATE_MD5=.*$|DOTENV_TEMPLATE_MD5=${REAL_DOTENV_TEMPLATE_MD5}|g" .env
}


create_default_directories_and_files () {
  TMP_FILE=$(mktemp)
  {
    create_directory_if_it_does_not_exist "_storage"
    create_directory_if_it_does_not_exist "_storage/example"
    create_directory_if_it_does_not_exist ".local"
    create_directory_if_it_does_not_exist ".local/example"
    create_file_if_it_does_not_exist ".local/example/.bash_history"
  } >> "${TMP_FILE}"
  if [ -n "$(cat "${TMP_FILE}")" ]
  then
    echo_title "Creating files and directories"
    echo_default "$(grep -v '^$' "${TMP_FILE}")"
  fi
  rm -f "${TMP_FILE}"
}


get_database_connection_string () {
  USER=${1:?}
  PASSWORD=${2:?}
  HOST=${3:?}
  DATABASE=${4:?}
  echo "postgresql+asyncpg://${USER}:${PASSWORD}@${HOST}/${DATABASE}"
}
