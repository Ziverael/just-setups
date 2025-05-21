#!/usr/bin/env sh

#This is for the monorepo flow with nested justscripts with common layout

# Define the project root directory
[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$(pwd)"

if [ -z "$PROJECT_NAME" ]; then
    echo "Error: PROJECT_NAME is required"
    exit 1
fi


# Alembic helpers

start_base_container_and_apply_migrations () {
  if [ "$(docker_container_is_running data_provider_db)" = "false" ]
  then
    echo_title "Starting data_provider_db"
    docker compose -f docker-compose.yaml up data_provider_db
  fi
  start_base_container_if_not_running
  docker exec -it "${PROJECT_NAME}"_base_container bash -c "poetry run alembic upgrade head"
}

# Linter, tests, checkers

format_python_code () {
  TARGET="${1:-./}"
    IGNORE="${2}"
    [ -f "${TARGET}" ] && [ "$(get_lowercase_file_extension "${TARGET}")" != "py" ]\
         && echo "Not a python file. Skipping" && return
    [ -n "${IGNORE}" ] && IGNORE="--ignore ${IGNORE}"
    start_base_container_if_not_running
    echo_title "Starting reformat with ruff"
    docker exec "${PROJECT_NAME}"_base_container poetry run ruff format "${TARGET}" || ERROR=$?
    # shellcheck disable=SC2086
    docker exec "${PROJECT_NAME}"_base_container poetry run ruff check --fix ${IGNORE} "${TARGET}" || ERROR=$?
    show_ruff_hints_if_error_encountered ${ERROR}
}

format_typescript_code(){
  TARGET="${1:-./}"
  start_base_container_if_not_running
  echo_title "Starting reformat with prettier and eslint"
  docker exec -it dot_base_container sh -c "pnpm prettier --write "${TARGET}""
  docker exec -it dot_base_container sh -c "pnpm eslint --fix "${TARGET}""
}

check_python_code () {
  start_base_container_if_not_running
    echo_title "Starting check with ruff"
    docker exec "${PROJECT_NAME}"_base_container poetry run ruff check . || ERROR=$?
    docker exec "${PROJECT_NAME}"_base_container poetry run ruff format --check . || ERROR=$?
    show_ruff_hints_if_error_encountered ${ERROR}
    echo_title "Starting check with mypy"
    docker exec "${PROJECT_NAME}"_base_container poetry run mypy --incremental --show-error-codes --pretty . || ERROR=$?
    return $ERROR
}

show_ruff_hints_if_error_encountered () {
    ERROR="${1}"
    if [ -n "${ERROR}" ]
    then
        echo_default "Rule details available at https://docs.astral.sh/ruff/rules/"
    fi
}


check_typescript_code () {
    start_base_container_if_not_running
    echo_title "Starting check with prettier"
    docker exec -it dot_base_container sh -c "pnpm prettier --check ./dot"  || ERROR=$?
    echo_title "Starting check with eslint"
    docker exec -it dot_base_container sh -c "pnpm eslint"  || ERROR=$?
    show_eslint_hints_if_error_encountered ${ERROR}
    return $ERROR
}

show_eslint_hints_if_error_encountered () {
    ERROR="${1}"
    if [ -n "${ERROR}" ]
    then
        echo_default "Rule details available at https://eslint.org/docs/latest/rules/"
        echo_default "Rule details available at https://typescript-eslint.io/rules/"
    fi
}

test_python_code () {
    TEST_PATH="${1:-./tests}"
    TEST_DATABASE_CONNECTION_STRING="${2:-undefined}"
    echo_title "Starting tests with pytest"
    start_base_container_if_not_running
    OPTS="${3}"
    OPTS="${OPTS} --cov ./${PROJECT_NAME}"
    OPTS="${OPTS} --cov-report html:./coverage/htmlcov"
    OPTS="${OPTS} --cov-report xml:./coverage/coverage.xml"
    OPTS="${OPTS} --cache-clear"
    OPTS="${OPTS} --pyargs ${TEST_PATH}"
    if [ "${TEST_DATABASE_CONNECTION_STRING}" != "undefined" ]
    then
      docker exec \
        -e ${upper_case_project_name}_DATABASE_CONNECTION_STRING=${TEST_DATABASE_CONNECTION_STRING}  \
        -it "${PROJECT_NAME}"_base_container poetry run pytest ${OPTS}
    else
      docker exec -it "${PROJECT_NAME}"_base_container poetry run pytest ${OPTS}
    fi
    echo "Coverage report available at $(pwd)/.local/${PROJECT_NAME}/coverage/htmlcov/index.html"
}

test_typescript_code () {
  TEST_PATH="${1:-./tests}"
  start_base_container_if_not_running
  echo_title "Starting tests with jest"
  docker exec -it dot_base_container sh -c "pnpm jest ${TEST_PATH}"
}

setup_db_for_tests () {
  DB_NAME="${1:?}"
  CONNECTION_STRING="${2:?}"
  upper_case_project_name=$(echo "${PROJECT_NAME}" | tr '[:lower:]' '[:upper:]')
  echo "Start services for tests"
  docker compose -f ../docker-compose.local.yaml up -d data_provider_db
  docker compose -f docker-compose.yaml up -d ${PROJECT_NAME}_start_tests_services
  echo_title "Setting up test database"
  docker exec -i data_provider_db bash -s "${DB_NAME}" < ../_scripts/create_test_db.sh
  echo_title "Applying migrations to the test database"
  docker exec -it	            																                                        \
      -e ${upper_case_project_name}_DATABASE_CONNECTION_STRING=${CONNECTION_STRING}  \
      "${PROJECT_NAME}"_base_container bash -c "poetry run alembic upgrade head"
}


profile_python_code () {
  FILE="${1:?}"
  start_base_container_if_not_running
  echo_title "Profiling with scalene"
  docker exec -it "${PROJECT_NAME}"_base_container poetry run scalene ${FILE} --html --outfile "scalene/$(basename "${FILE%.*}").html"
  echo_title "Opening scalene report in default browser"
  open_in_browser ".local/${PROJECT_NAME}/scalene/$(basename "${FILE%.*}").html"
}

# Shells

bash_shell () {
    echo_title "Starting bash session in base container"
    start_base_container_if_not_running
    docker exec -it "${PROJECT_NAME}"_base_container poetry run bash
}

sh_shell () {
    echo_title "Starting sh session in base container"
    start_base_container_if_not_running
    docker exec -it "${PROJECT_NAME}"_base_container sh
}


python_shell () {
    echo_title "Starting python session in base container"
    start_base_container_if_not_running
    docker exec -it "${PROJECT_NAME}"_base_container poetry run ipython
}

open_coverage_report () {
    echo_title "Opening coverage report"
    if [ -f ".local/${PROJECT_NAME}/coverage/htmlcov/index.html" ]
    then
        firefox .local/${PROJECT_NAME}/coverage/htmlcov/index.html
    else
        echo_error "Coverage report not found"
    fi   
}

clean_pycached () {
    echo_title "Removing all __pycache__ directories and *.py[cod] files"
    find . -type f -name "*.py[cod]" -delete -or -type d -name "__pycached__" -delete
    echo_default "Done"
}



# .env helpers

store_variable_in_dotenv_file () {
  VARIABLE_NAME="${1:?}"
  VARIABLE_VALUE="${2:?}"
  echo_default "Storing ${VARIABLE_NAME} default value."
  sed_inplace "s|^${VARIABLE_NAME}=.*$|${VARIABLE_NAME}=${VARIABLE_VALUE}|g" .env
}

restore_variable_in_dotenv_file () {
  VARIABLE_NAME="${1:?}"
  VARIABLE_VALUE=""
  [ -f .local/.env.backup ] && VARIABLE_VALUE="$(grep -m 1 -e "^${VARIABLE_NAME}=" .local/.env.backup | cut -d '=' -f2)"
  VARIABLE_VALUE_IN_DOTENV_TEMPLATE="$(grep -m 1 -e "^${VARIABLE_NAME}=" .env.template | cut -d '=' -f2)"
  if [ -n "${VARIABLE_VALUE}" ] && [ "${VARIABLE_VALUE}" != "${VARIABLE_VALUE_IN_DOTENV_TEMPLATE}" ]
  then
    echo_default "Restoring ${VARIABLE_NAME} value."
    sed_inplace "s|^${VARIABLE_NAME}=.*$|${VARIABLE_NAME}=${VARIABLE_VALUE}|g" .env
  fi
}

get_variable_from_dotenv_file () {
  VARIABLE_NAME="${1:?}"
  if [ ! -f .env ]
  then
    TARGET_ENV_FILE=".env.template"
  else 
    TARGET_ENV_FILE=".env"
  fi
  VARIABLE_VALUE="$(grep -m 1 -e "^${VARIABLE_NAME}=" "${TARGET_ENV_FILE}" | cut -d '=' -f2)"
  VARIABLE_VALUE_WITHOUT_TRAILING_QUOTES="${VARIABLE_VALUE%\"}"
  VARIABLE_VALUE_WITHOUT_LEADING_QUOTES="${VARIABLE_VALUE_WITHOUT_TRAILING_QUOTES#\"}"
  echo "${VARIABLE_VALUE_WITHOUT_LEADING_QUOTES}"
}

# Directory & files helpers

create_directory_if_it_does_not_exist () {
  DIRECTORY="${1:?}"
  [ ! -d "${DIRECTORY}" ] && mkdir -p "${DIRECTORY}" && echo "Directory ${DIRECTORY} created." || echo
}

create_file_if_it_does_not_exist () {
  FILENAME="${1:?}"
  [ -d "${FILENAME}" ] && rm -rdf "${FILENAME}" && echo "Removing directory ${FILENAME}."
  [ ! -f "${FILENAME}" ] && touch "${FILENAME}" && echo "File ${FILENAME} created." || echo
}   

create_symlink_to_target () {
  SYMLINK="${1:?}"
  TARGET="${2:?}"
  [ -L "$SYMLINK" ] && rm "$SYMLINK"
  ln -sf $(realpath "$TARGET") "$SYMLINK"
}

copy_directory_content_to_directory () {
  SOURCE="${1:?}"
  TARGET="${2:?}"
  [ ! -d  "$SOURCE" ] && return 1
  [ -d "$TARGET" ] && rm -rf "$TARGET"
  cp -r "$SOURCE" "$TARGET"
}


image_version(){
  if [ "$(is_git_working_tree_clean)" = "true" ]
  then
    echo "$(get_current_commit_utc_time)-$(get_current_commit_short_sha)"
  else
    echo "$(get_current_commit_utc_time)-$(get_current_commit_short_sha)-WIP-$(date +"%Y-%m-%d-%H-%M-%S")"
  fi
}

copy_poetry_lock_file_from_data_provider_image_if_it_does_not_exist(){
  [ -d "poetry.lock" ] && rm -rdf poetry.lock
  if [ ! -f "poetry.lock" ]
  then
    echo_default "Copying poetry.lock file from the tao base image"
    TEMPORARY_CONTAINER=$(docker create tao_image)
    docker cp -q "${TEMPORARY_CONTAINER}":/opt/tao/poetry.lock poetry.lock
    docker rm -fv "${TEMPORARY_CONTAINER}" 1>/dev/null
  fi
}

start_base_container_if_not_running () {
  start_service_if_it_is_not_running docker-compose.yaml "${PROJECT_NAME}"_base_container
}

stop_base_container_if_running () {
  stop_service_if_it_is_running docker-compose.yaml "${PROJECT_NAME}"_base_container
}



# Shell helpers
TITLE="\033[94m\033[1m"
HIGHLIGHT="\033[93m\033[1m"
WARNING="\033[91m\033[1m"
DEFAULT="\033[0m"

echo_default(){
  echo "${DEFAULT}${1}"
}

echo_title(){
  echo "${TITLE}${1}${DEFAULT}"
}

echo_highlight(){
  echo "${HIGHLIGHT}${1}${DEFAULT}"
}

echo_warning(){
  echo "${WARNING}${1}${DEFAULT}"
}

is_arm_architecture(){
  { [ "$(uname -p)" = "arm" ] || [ "${IS_ARM_ARCHITECTURE}" = "true" ]; } && echo true || echo "false"
}

sed_inplace(){
  if [ "$(is_arm_architecture)" = "true" ]
  then
    # MacOS invocation
    sed -i '' "$@"
  else
    # Linux invocation
    sed -i "$@"
  fi
}

get_lowercase_file_extension(){
  FILENAME="${1:?}"
  LOWERCASE_FILENAME="$(echo "${FILENAME}" | tr '[:upper:]' '[:lower:]')"
  LOWERCASE_EXTENSION="${LOWERCASE_FILENAME##*.}"
  [ "${LOWERCASE_FILENAME}" != "${LOWERCASE_EXTENSION}" ] && echo "${LOWERCASE_EXTENSION}"
}

# Git helpers

get_current_commit_short_sha(){
  git rev-parse --short=8 HEAD
}

get_current_commit_utc_time(){
  TZ=UTC git show -s --format=%cd --date=iso-local HEAD | sed 's/ +0000$//' | sed 's/[ :]/-/g'
}

is_git_working_tree_clean(){
  PATH_TO_FOLDER="${1:-.}"
  git diff --quiet "${PATH_TO_FOLDER}" ; [ $? -eq 0 ] && echo "true" || echo "false"
}

# Docker helpers

docker_network_exists(){
  NETWORK="${1:?}"
  [ "$(docker network ls | grep -w "${NETWORK}")" != "" ] && echo "true" || echo "false"
}

docker_image_exists(){
  IMAGE_NAME="${1:?}"
  [ "$(docker images --quiet "${IMAGE_NAME}")" != "" ] && echo "true" || echo "false"
}

docker_container_is_running(){
  TEMPORARY_CONTAINER="${1:?}"
  [ "$(docker inspect -f '{{.State.Running}}' "${TEMPORARY_CONTAINER}" 2> /dev/null)" = "true" ] && echo "true" || echo "false"
}

conflicting_docker_container_exists(){
  TEMPORARY_CONTAINER="${1:?}"
  CURRENT_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}"
  CONTAINER_EXISTS="$([ -n "$(docker ps --quiet --all --filter name="^${TEMPORARY_CONTAINER}$")" ] && echo "true" || echo "false")"
  CONTAINER_PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${TEMPORARY_CONTAINER}" 2> /dev/null)"
  [ "${CONTAINER_EXISTS}" = "true" ] && [ "${CONTAINER_PROJECT}" != "${CURRENT_PROJECT}" ] && echo "true" || echo "false"
}

conflicting_docker_container_is_running(){
  TEMPORARY_CONTAINER="${1:?}"
  [ "$(docker_container_is_running "${TEMPORARY_CONTAINER}")" = "true" ] && [ "$(conflicting_docker_container_exists "${TEMPORARY_CONTAINER}")" = "true" ] && echo "true" || echo "false"
}

conflicting_docker_container_is_stopped(){
  TEMPORARY_CONTAINER="${1:?}"
  [ "$(docker_container_is_running "${TEMPORARY_CONTAINER}")" = "false" ] && [ "$(conflicting_docker_container_exists "${TEMPORARY_CONTAINER}")" = "true" ] && echo "true" || echo "false"
}

create_shared_network(){
  NETWORK="${1:?}"
	if [ "$(docker_network_exists "${NETWORK}")" != "true" ]
	then
		echo_title "Creating network ${NETWORK}"
		docker network create "${NETWORK}"
	fi
}

validate_if_image_exists(){
  IMAGE="${1:?}"
  if [ "$(docker_image_exists "${IMAGE}")" != "true" ]
  then
      echo_title "Checking if image ${IMAGE} exists"
      echo_warning "Image ${HIGHLIGHT}${IMAGE}${WARNING} is missing." 1>&2
      return 1
  fi
}

start_service_if_it_is_not_running(){
  COMPOSE_FILE="${1:?}"
  SERVICE="${2:?}"
  if [ "$(docker_container_is_running "${SERVICE}")" != "true" ]
  then
    echo_title "Starting ${SERVICE} service"
    docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE}"
	fi
}

stop_service_if_it_is_running(){
  COMPOSE_FILE="${1:?}"
  SERVICE="${2:?}"
  if [ "$(docker_container_is_running "${SERVICE}")" = "true" ]
  then
    echo_title "Stopping ${SERVICE} service"
    docker compose -f "${COMPOSE_FILE}" down "${SERVICE}"
	fi
}


open_in_browser(){
  FILE="${1:?}"
  if [ -f "${FILE}" ]
  then
    nohup xdg-open "${FILE}" > /dev/null 2>&1 &
  fi
}