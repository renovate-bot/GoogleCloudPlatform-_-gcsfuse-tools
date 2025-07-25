#!/bin/bash
#
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is for running fio/dlio tests using GKE.
# This is a stand-alone script, and can be invoked directly by a user.
# It takes in parameters through environment variables. For learning about them, run this script with `--help` argument.
# For debugging, pass argument `--debug` which will print all the shell commands that runs.
# It fetches gcsfuse, gcsfuse-tools and GKE GCSFuse CSI driver (gcs-fuse-csi-driver) code from github, if you don't provide it pre-existing clones of them.
# It installs all the necessary dependencies on its own.
# It creates a GKE cluster and other GCP resources (as needed), based on a number of configuration parameters e.g. gcp-project-name/number, cluster-name, zone (for resource location), machine-type (of node), number of local SSDs.
# It creates fio/dlio tests as helm charts, based on the provided JSON workload configuration file and deploys them on the GKE cluster.
# A sample workload-configuration file is available at https://github.com/GoogleCloudPlatform/gcsfuse-tools/blob/main/testing_on_gke/examples/workloads.json .

# Fail script if any of the commands fail.
set -e

# Print all the shell commands if the user passes argument `--debug`. This is
# useful for debugging the script.
if ([ $# -gt 0 ] && ([ "$1" == "-debug" ] || [ "$1" == "--debug" ])); then
  set -x
fi

# Utilities
function exitWithSuccess() { exit 0; }
function exitWithFailure() { exit 1; }
function echoerror()  { >&2 echo "Error: "$@ ; }
function echowarning()  { >&2 echo "Warning: "${@} ; }
function exitWithError()  { echoerror "$@" ; exitWithFailure ; }
function returnWithError()  { echoerror "$@" ; return 1 ; }

# Default values, to be used for parameters in case user does not specify them.
# GCP related
readonly DEFAULT_ZONE="us-west1-b"
# GKE cluster related
readonly DEFAULT_NODE_POOL=default-pool
readonly DEFAULT_MACHINE_TYPE="n2-standard-96"
readonly DEFAULT_NUM_NODES=8
readonly DEFAULT_NUM_SSD=16
readonly DEFAULT_APPNAMESPACE=default
readonly DEFAULT_KSA=default
readonly DEFAULT_USE_CUSTOM_CSI_DRIVER=true
readonly DEFAULT_CUSTOM_CSI_DRIVER=
# GCSFuse tools/GKE GCSFuse CSI Driver source code related
readonly DEFAULT_SRC_DIR="$(realpath .)/src"
readonly csi_driver_github_path=https://github.com/googlecloudplatform/gcs-fuse-csi-driver
readonly csi_driver_branch=main
readonly gcsfuse_tools_github_path=https://github.com/googlecloudplatform/gcsfuse-tools
readonly DEFAULT_GCSFUSE_TOOLS_BRANCH=main
readonly gcsfuse_github_path=https://github.com/googlecloudplatform/gcsfuse
readonly DEFAULT_GCSFUSE_BRANCH=master
# Test runtime configuration
# 5 minutes
readonly DEFAULT_POD_WAIT_TIME_IN_SECONDS=300
# 1 week
readonly DEFAULT_POD_TIMEOUT_IN_SECONDS=604800
readonly DEFAULT_FORCE_UPDATE_GCSFUSE_TOOLS_CODE=false
readonly DEFAULT_FORCE_UPDATE_GCSFUSE_CODE=false
readonly DEFAULT_ZONAL=false

# Config for exporting fio outputs to a Bigquery table.
readonly DEFAULT_BQ_PROJECT_ID='gcs-fuse-test-ml'
readonly DEFAULT_BQ_DATASET_ID='gke_test_tool_outputs'
readonly DEFAULT_BQ_TABLE_ID='fio_outputs'

# Handling of deprecated flag instance_id if it has been passed.
if test -n "${instance_id}" ; then
  deprecation_message="instance_id flag is now deprecated, but has been passed (with value \"${instance_id}\"). In future, please use experiment_id instead."

  # If instance_id is set, but experiment_id is not
  # set, then let this be only a warning message and pass the value of
  # instance_id to experiment_id.
  if test -z "${experiment_id}" ; then
    echowarning ${deprecation_message}" For now, setting experiment_id=\"${instance_id}\" ."
    export experiment_id="${instance_id}"
    unset instance_id
  else
    # Otherwise, halt the run as this is an ambiguous situation.
    exitWithError "${deprecation_message}"
  fi
fi

# Create and return a unique experiment_id taking
# into account user's passed experiment_id.
function create_unique_experiment_id() {
  new_uuid=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
  local generated_unique_experiment_id=${USER}-$(date +%Y%m%d-%H%M%S)-${new_uuid}
  if [ $# -gt 0 ] && [ -n "${1}" ]; then
    local user_provided_experiment_id="${1}"
    experiment_id=${user_provided_experiment_id// /-}"-"${generated_unique_experiment_id}
  else
    experiment_id=${generated_unique_experiment_id}
  fi
  echo "${experiment_id}"
}

function printHelp() {
  echo "Usage guide: "
  echo "[ENV_OPTIONS] "${0}" [ARGS]"
  echo ""
  echo "ENV_OPTIONS (all are optional): "
  echo ""
  # GCP related
  echo "project_id=<project-id>"
  echo "project_number=<number>"
  echo "zone=<region-zone default=\"${DEFAULT_ZONE}\">"
  # GKE cluster related
  echo "cluster_name=<cluster-name>"
  echo "node_pool=<pool-name default=\"${DEFAULT_NODE_POOL}\">"
  echo "machine_type=<machine-type default=\"${DEFAULT_MACHINE_TYPE}\">"
  echo "num_nodes=<number from 1-8, default=\"${DEFAULT_NUM_NODES}\">"
  echo "num_ssd=<number from 0-16, default=\"${DEFAULT_NUM_SSD}\">"
  echo "custom_csi_driver=<string representing the full path of the csi-driver image hash e.g. gcr.io/<registry-name>:<hash>, default=\"${DEFAULT_CUSTOM_CSI_DRIVER}\". If it is non-empty, then use_custom_csi_driver is assumed true, but a custom driver is not built and the given custom csi driver is used instead. >"
  echo "use_custom_csi_driver=<true|false, true means build and use a new custom csi driver using gcsfuse code, default=\"${DEFAULT_USE_CUSTOM_CSI_DRIVER}\">"
  # GCSFuse/GKE GCSFuse CSI Driver source code related
  echo "src_dir=<\"directory/to/clone/github/repos/if/needed\", used for creating local clones of repos in case when gcsfuse, gcsfuse_tools_src_dir or csi_src_dir are not passed, default=\"${DEFAULT_SRC_DIR}\">"
  echo "gcsfuse_tools_branch=<name-of-gcsfuse-tools-branch-for-cloning>, used for locally cloning, in case gcsfuse_tools_src_dir has not been passed, default=\"${DEFAULT_GCSFUSE_TOOLS_BRANCH}\">"
  echo "gcsfuse_tools_src_dir=<\"/path/of/gcsfuse-tools/src/to/use/if/available\", default=\"${DEFAULT_SRC_DIR}/gcsfuse-tools\">"
  echo "gcsfuse_branch=<name-of-gcsfuse-branch-for-cloning>, used for locally cloning, in case gcsfuse_src_dir has not been passed, default=\"${DEFAULT_GCSFUSE_BRANCH}\">"
  echo "gcsfuse_src_dir=<\"/path/of/gcsfuse/src/to/use/if/available\", default=\"${DEFAULT_SRC_DIR}/gcsfuse\">"
  echo "csi_src_dir=<\"/path/of/gcs-fuse-csi-driver/to/use/if/available\", default=\"${DEFAULT_SRC_DIR}\"/gcs-fuse-csi-driver>"
  # Test runtime configuration
  echo "pod_wait_time_in_seconds=<number e.g. 60 for checking pod status every 1 min, default=\"${DEFAULT_POD_WAIT_TIME_IN_SECONDS}\">"
  echo "pod_timeout_in_seconds=<number e.g. 3600 for timing out pod runs, should be more than the value of pod_wait_time_in_seconds, default=\"${DEFAULT_POD_TIMEOUT_IN_SECONDS}\">"
  echo "experiment_id=<Optional description of this particular test-run, it does not need to be unique e.g. \"cache test #43\""
  echo "workload_config=<path/to/workload/configuration/file e.g. /a/b/c.json >"
  echo "output_dir=</absolute/path/to/output/dir, output files will be written at output_dir/fio/output.csv and output_dir/dlio/output.csv>"
  echo "force_update_gcsfuse_tools_code=<true|false, to force-update the gcsfuse-tools code to given branch if gcsfuse_tools_src_dir has been set. Default=\"${DEFAULT_FORCE_UPDATE_GCSFUSE_TOOLS_CODE}\">"
  echo "force_update_gcsfuse_code=<true|false, to force-update the gcsfuse-code to given branch if gcsfuse_src_dir has been set. Default=\"${DEFAULT_FORCE_UPDATE_GCSFUSE_CODE}\">"
  echo "zonal=<true|false, to convey that at least one of the buckets in the given workload configuration is a zonal bucket which can't be read/written using gcloud. Default=\"${DEFAULT_ZONAL}\"> "
  echo ""
  echo ""
  echo ""
  echo "ARGS (all are optional) : "
  echo ""
  echo "--debug     Print out shell commands for debugging. Aliases: -debug "
  echo "--help      Print out this help. Aliases: -help, -h"
}

# Print out help if user passes argument `--help`
if ([ $# -gt 0 ] && ([ "$1" == "-help" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ])); then
  printHelp
  exitWithSuccess
fi

verify_csi_driver_image() {
  if [[ $# < 1 ]]; then
    returnWithError "No arguments passed to verify_csi_driver_image. Expected: \$1=<csi-driver-image> ."
  fi
  local csi_driver_image=${1}
  echo "Checking ${csi_driver_image} ..."
  if ! gcloud -q container images describe ${csi_driver_image} >/dev/null; then
    returnWithError "${csi_driver_image} is not a valid GCSFuse csi driver image.  !!! Please check if you missed adding /gcs-fuse-csi-driver-sidecar-mounter before the hash. !!!"
  fi
}

# Set environment variables.
# GCP related
if test -z "${project_id}"; then
    exitWithError "project_id was not set"
fi
if test -z "${project_number}"; then
    exitWithError "project_number was not set"
fi
test -n "${zone}" || export zone=${DEFAULT_ZONE}
# GKE cluster related
if test -z "${cluster_name}"; then
  exitWithError "cluster_name was not set."
fi
test -n "${node_pool}" || export node_pool=${DEFAULT_NODE_POOL}
test -n "${machine_type}" || export machine_type=${DEFAULT_MACHINE_TYPE}
test -n "${num_nodes}" || export num_nodes=${DEFAULT_NUM_NODES}
test -n "${num_ssd}" || export num_ssd=${DEFAULT_NUM_SSD}
# test -n "${appnamespace}" ||
export appnamespace=${DEFAULT_APPNAMESPACE}
# test -n "${ksa}" ||
export ksa=${DEFAULT_KSA}

applied_custom_csi_driver=
if test -z "${custom_csi_driver}"; then
  echo "custom_csi_driver has not been set, so assuming \"${DEFAULT_CUSTOM_CSI_DRIVER}\" for it ..."
  export custom_csi_driver="${DEFAULT_CUSTOM_CSI_DRIVER}"
  if test -z "${use_custom_csi_driver}"; then
    echo "use_custom_csi_driver has not been set, so assuming \"${DEFAULT_USE_CUSTOM_CSI_DRIVER}\" for it ..."
    export use_custom_csi_driver="${DEFAULT_USE_CUSTOM_CSI_DRIVER}"
  elif [[ ${use_custom_csi_driver} = "true" ]]; then
    echo "User has enabled use_custom_csi_driver, without passing a custom_csi_driver, so a custom driver will be built in this run."
  elif [[ ${use_custom_csi_driver} != "false" ]]; then
    exitWithError "Unsupported value passed for use_custom_csi_driver: ${use_custom_csi_driver}. Supported values: true/false ."
  fi
else
  echo "User passed custom_csi_driver=${custom_csi_driver}. This will be used this run."
  printf "\nVerifying that ${custom_csi_driver} is a valid GCSFuse csi driver image ...\n\n"
  verify_csi_driver_image ${custom_csi_driver}
  if test -z "${use_custom_csi_driver}"; then
    echo "use_custom_csi_driver has not been set, so setting it to true as custom_csi_driver has been set to \"${custom_csi_driver}\""
    export use_custom_csi_driver=true
  elif [[ ${use_custom_csi_driver} = "false" ]]; then
    exitWithError "User has disabled use_custom_csi_driver, while passing a custom_csi_driver. This is unsupported."
  elif [[ ${use_custom_csi_driver} != "true" ]]; then
    exitWithError "Unsupported value passed for use_custom_csi_driver: ${use_custom_csi_driver}. Supported values: true or false ."
  fi
  applied_custom_csi_driver=${custom_csi_driver}
fi

test -n "${gcsfuse_tools_branch}" || export gcsfuse_tools_branch="${DEFAULT_GCSFUSE_TOOLS_BRANCH}"
test -n "${gcsfuse_branch}" || export gcsfuse_branch="${DEFAULT_GCSFUSE_BRANCH}"

# GCSFuse/GKE GCSFuse CSI Driver source code related
if test -n "${src_dir}"; then
  if ! test -d "${src_dir}"; then
    exitWithError "src_dir \"${src_dir}\" does not exist"
  fi
  export src_dir="$(realpath "${src_dir}")"
else
  export src_dir=${DEFAULT_SRC_DIR}
  mkdir -pv "${src_dir}"
fi

if test -n "${gcsfuse_tools_src_dir}"; then
  if ! test -d "${gcsfuse_tools_src_dir}"; then
    exitWithError "gcsfuse_tools_src_dir \"${gcsfuse_tools_src_dir}\" does not exist"
  fi
  export gcsfuse_tools_src_dir="$(realpath "${gcsfuse_tools_src_dir}")"
else
  export gcsfuse_tools_src_dir="${src_dir}"/gcsfuse-tools
fi

if test -z "${force_update_gcsfuse_tools_code}"; then
  export force_update_gcsfuse_tools_code=${DEFAULT_FORCE_UPDATE_GCSFUSE_TOOLS_CODE}
fi

export gke_testing_dir="${gcsfuse_tools_src_dir}"/testing_on_gke

if test -n "${gcsfuse_src_dir}"; then
  if ! test -d "${gcsfuse_src_dir}"; then
    exitWithError "gcsfuse_src_dir has been passed as \"${gcsfuse_src_dir}\", which does not exist"
  fi
  export gcsfuse_src_dir="$(realpath "${gcsfuse_src_dir}")"
fi

if test -n "${csi_src_dir}"; then
  if ! test -d "${csi_src_dir}"; then
    exitWithError "csi_src_dir \"${csi_src_dir}\" does not exist"
  fi
  export csi_src_dir="$(realpath "${csi_src_dir}")"
fi

# Test runtime configuration
test -n "${pod_wait_time_in_seconds}" || export pod_wait_time_in_seconds="${DEFAULT_POD_WAIT_TIME_IN_SECONDS}"
test -n "${pod_timeout_in_seconds}" || export pod_timeout_in_seconds="${DEFAULT_POD_TIMEOUT_IN_SECONDS}"

if test -z ${only_parse} ; then
  export only_parse=false
elif [ "$only_parse" != "true" ] && [ "$only_parse" != "false" ]; then
  exitWithError "Unexpected value of only_parse: ${only_parse}. Expected: true or false ."
fi

# If user passes only_parse=true, then expect an experiment_id
# also with it, and use it as it is.
if ${only_parse}; then
  if [ -z "${experiment_id}" ]; then
    exitWithError "experiment_id not passed with only_parse=true"
  fi
else
  # create a new experiment_id
  export user_passed_experiment_id="${experiment_id}"
  export experiment_id=$(create_unique_experiment_id "${user_passed_experiment_id}")
fi

if [[ ${pod_timeout_in_seconds} -le ${pod_wait_time_in_seconds} ]]; then
  exitWithError "pod_timeout_in_seconds (${pod_timeout_in_seconds}) <= pod_wait_time_in_seconds (${pod_wait_time_in_seconds})"
fi

if test -n "${workload_config}"; then
  if ! test -f "${workload_config}"; then
    exitWithError "workload_config \"${workload_config}\" does not exist"
  fi
  export workload_config="$(realpath "${workload_config}")"
else
    export workload_config="${gke_testing_dir}"/examples/workloads.json
fi

if test -n "${output_dir}"; then
  if ! test -d "${output_dir}"; then
    exitWithError "output_dir \"${output_dir}\" does not exist"
  fi
  export output_dir="$(realpath "${output_dir}")"
else
  export output_dir="${gke_testing_dir}"/examples
fi

if test -z "${zonal}"; then
  echo "env var zonal not set, so assuming ${DEFAULT_ZONAL} for it."
  export zonal=${DEFAULT_ZONAL}
elif [[ ${zonal} != "true" && "${zonal}" != "false" ]]; then
  exitWithError "env var zonal should be set as false, or true, but received: ${zonal}"
fi

function printRunParameters() {
  echo "Running $0 with following parameters:"
  echo ""
  # GCP related
  echo "project_id=\"${project_id}\""
  echo "project_number=\"${project_number}\""
  echo "zone=\"${zone}\""
  # GKE cluster related
  echo "cluster_name=\"${cluster_name}\""
  echo "node_pool=\"${node_pool}\""
  echo "machine_type=\"${machine_type}\""
  echo "num_nodes=\"${num_nodes}\""
  echo "num_ssd=\"${num_ssd}\""
  echo "appnamespace=\"${appnamespace}\""
  echo "ksa=\"${ksa}\""
  echo "use_custom_csi_driver=\"${use_custom_csi_driver}\""
  echo "custom_csi_driver=\"${custom_csi_driver}\""
  # GCSFuse/GKE GCSFuse CSI Driver source code related
  echo "src_dir=\"${src_dir}\""
  echo "gcsfuse_tools_src_dir=\"${gcsfuse_tools_src_dir}\""
  if test -n "${gcsfuse_src_dir}"; then
    echo "gcsfuse_src_dir=\"${gcsfuse_src_dir}\""
  fi
  if test -n "${csi_src_dir}"; then
    echo "csi_src_dir=\"${csi_src_dir}\""
  fi
  echo "gke_testing_dir=\"${gke_testing_dir}\""
  # Test runtime configuration
  echo "pod_wait_time_in_seconds=\"${pod_wait_time_in_seconds}\""
  echo "pod_timeout_in_seconds=\"${pod_timeout_in_seconds}\""
  echo "experiment_id=User passed: \"${user_passed_experiment_id}\", internally created: \"${experiment_id}\""
  echo "workload_config=\"${workload_config}\""
  echo "output_dir=\"${output_dir}\""
  echo "force_update_gcsfuse_tools_code=\"${force_update_gcsfuse_tools_code}\""
  if test -n "${force_update_gcsfuse_code}"; then
    echo "force_update_gcsfuse_code=\"${force_update_gcsfuse_code}\""
  fi
  echo "zonal=\"${zonal}\""
  if ${only_parse}; then
    echo "only_parse=${only_parse}"
  fi
  echo ""
  echo ""
  echo ""
}

# Install dependencies.
function installDependencies() {
  printf "\nInstalling dependencies ...\n\n"
  # Refresh software repositories.
  sudo apt-get update >/dev/null
  # Get some common software dependencies.
  sudo apt-get install -y apt-transport-https ca-certificates gnupg curl >/dev/null
  # Ensure that realpath is installed.
  which realpath >/dev/null
  # Ensure that make is installed.
  which make >/dev/null || ( sudo apt-get install -y make time >/dev/null && which make >/dev/null )
  # Ensure that go is installed.
  which go >/dev/null || (version=1.22.4 && wget -O go_tar.tar.gz https://go.dev/dl/go${version}.linux-amd64.tar.gz 1>/dev/null && sudo rm -rf /usr/local/go && tar -xzf go_tar.tar.gz 1>/dev/null && sudo mv go /usr/local && echo $PATH && export PATH=$PATH:/usr/local/go/bin && echo $PATH && echo 'export PATH=$PATH:/usr/local/go/bin'>>~/.bashrc && go version)
  # for some reason, the above is unable to update the value of $PATH, so doing it explicitly below.
  export PATH=$PATH:/usr/local/go/bin
  which go >/dev/null
  # Ensure that python3 is installed.
  which python3 >/dev/null || ( sudo apt-get install -y python3 >/dev/null && which python3 >/dev/null )
  # Install more python tools.
  sudo apt-get -y install python3-dev python3-venv python3-pip >/dev/null
  # Enable python virtual environment.
  python3 -m venv .venv >/dev/null
  source .venv/bin/activate >/dev/null
  # Ensure that pip is installed.
  sudo apt-get install -y pip >/dev/null
  # python3 -m pip install --upgrade pip
  # python3 -m pip --version
  # Ensure that python-absl is installed.
  pip install absl-py >/dev/null
  # Ensure that helm is installed
  which helm >/dev/null || (cd "${src_dir}" && (test -d "./helm" || git clone https://github.com/helm/helm.git) && cd helm && make && ls -lh bin/ && mkdir -pv ~/bin && cp -fv bin/helm ~/bin/ && chmod +x ~/bin/helm && export PATH=$PATH:$HOME/bin && echo $PATH && which helm && cd - >/dev/null && cd - >/dev/null)
  # for some reason, the above is unable to update the value of $PATH, so doing it explicitly below.
  export PATH=$PATH:$HOME/bin
  which helm >/dev/null
  # Ensure that kubectl is installed
  if ! which kubectl >/dev/null ; then
    # Install the latest gcloud cli. Find full instructions at https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl .
    # Import the Google Cloud public key (Debian 9+ or Ubuntu 18.04+)
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg
    # Add the gcloud CLI distribution URI as a package source (Debian 9+ or Ubuntu 18.04+)
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    # Update and install the gcloud CLI
    sudo apt-get update >/dev/null
    sudo apt-get install -y google-cloud-cli >/dev/null
    # install kubectl
    gcloud components install kubectl >/dev/null || sudo apt-get install -y kubectl >/dev/null
    kubectl version --client
  fi
  # Ensure that gke-gcloud-auth-plugin is installed.
  gke-gcloud-auth-plugin --version || ((gcloud components install gke-gcloud-auth-plugin >/dev/null || sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin >/dev/null) && gke-gcloud-auth-plugin --version)
  # Ensure that docker is installed.
  if ! which docker >/dev/null ; then
    sudo apt install apt-transport-https ca-certificates curl software-properties-common -y >/dev/null
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
    apt-cache policy docker-ce
    sudo apt install docker-ce -y >/dev/null
  fi
  # Ensure that gcloud monitoring tools are installed.
  pip install --upgrade google-cloud-storage 1>/dev/null
  pip install --ignore-installed --upgrade google-api-python-client 1>/dev/null
  pip install --ignore-installed --upgrade google-cloud 1>/dev/null
  pip install --upgrade google-cloud-monitoring 1>/dev/null
  # Ensure that jq is installed.
  which jq >/dev/null || sudo apt-get install -y jq >/dev/null
  # Ensure sudoless docker is installed.
  if ! docker ps 1>/dev/null ; then
    echoerror "sudoless docker is not installed on this machine ($(hostname)). Please install sudoless-docker using the following commands and re-run this script ($0)"
    echoerror "sudo addgroup docker && sudo usermod -aG docker $USER && newgrp docker"
    return 1
  fi
  # Install python client for bigquery.
  # TODO: Make this conditional on bigquery export !
  pip3 install --upgrade google-cloud-bigquery >/dev/null
  pip3 install --upgrade google-cloud-storage >/dev/null
  pip install google-api-python-client >/dev/null
}

# Make sure you have access to the necessary GCP resources. The easiest way to enable it is to use <your-ldap>@google.com as active auth.
function ensureGcpAuthsAndConfig() {
  # gcloud auth application-default login --no-launch-browser
  gcloud auth list
  # grep -q ${USER}
  gcloud config set project ${project_id}
  gcloud config list
}

# Verify that the passed machine configuration parameters (machine-type, num-nodes, num-ssd) are compatible.
# This is to fail fast, right at the start of the script, rather than failing at
# cluster/nodepool creation, which takes a lot longer.
# Source of constraints:
# https://cloud.google.com/compute/docs/disks/local-ssd#lssd_disk_options .
function validateMachineConfig() {
  echo "Validating input machine configuration ..."
  local machine_type=${1}
  local num_nodes=${2}
  local num_ssd=${3}

  if test ${num_nodes} -le 0; then
    echo "num_nodes is too low (minimium=1) at "${num_nodes}
  fi

  case "${machine_type}" in
  "n2-standard-96")
    if [ ${num_ssd} -ne 0 -a ${num_ssd} -ne 16 -a ${num_ssd} -ne 24 ]; then
      echoerror "Unsupported num-ssd "${num_ssd}" with given machine-type "${machine_type}". It should be 0, 16 or 24"
      return 1
    fi
    ;;
  "n2-standard-48")
    if [ ${num_ssd} -ne 0 -a ${num_ssd} -ne 8 -a ${num_ssd} -ne 16 -a ${num_ssd} -ne 24 ]; then
      echoerror "Unsupported num-ssd "${num_ssd}" with given machine-type "${machine_type}". It should be 0, 8, 16 or 24"
      return 1
    fi
    ;;
  "n2-standard-32")
    if [ ${num_ssd} -ne 0 -a ${num_ssd} -ne 4 -a ${num_ssd} -ne 8 -a ${num_ssd} -ne 16 -a ${num_ssd} -ne 24 ]; then
      echoerror "Unsupported num-ssd "${num_ssd}" with given machine-type "${machine_type}". It should be 0, 4, 8, 16 or 24"
      return 1
    fi
    ;;
  *) ;;
  esac

  return 0
}

function doesNodePoolExist() {
  local cluster_name=${1}
  local zone=${2}
  local node_pool=${3}
  gcloud container node-pools list --project=${project_id} --cluster=${cluster_name} --zone=${zone} | grep -owq ${node_pool}
}

function deleteExistingNodePool() {
  local cluster_name=${1}
  local zone=${2}
  local node_pool=${3}
  if doesNodePoolExist ${cluster_name} ${zone} ${node_pool}; then
    gcloud -q container node-pools delete ${node_pool} --project=${project_id} --cluster ${cluster_name} --zone ${zone}
  fi
}

function resizeExistingNodePool() {
  local cluster_name=${1}
  local zone=${2}
  local node_pool=${3}
  local num_nodes=${4}
  if doesNodePoolExist ${cluster_name} ${zone} ${node_pool}; then
    gcloud -q container clusters resize ${cluster_name} --project=${project_id} --node-pool=${node_pool} --num-nodes=${num_nodes} --zone ${zone}
  fi
}

function createNewNodePool() {
  local cluster_name=${1}
  local zone=${2}
  local node_pool=${3}
  local machine_type=${4}
  local num_nodes=${5}
  local num_ssd=${6}
  gcloud container node-pools create ${node_pool} --project=${project_id} --cluster ${cluster_name} --ephemeral-storage-local-ssd count=${num_ssd} --network-performance-configs=total-egress-bandwidth-tier=TIER_1 --machine-type ${machine_type} --zone ${zone} --num-nodes ${num_nodes} --workload-metadata=GKE_METADATA --enable-gvnic
}

function getMachineTypeInNodePool() {
  local cluster=${1}
  local node_pool=${2}
  local zone=${3}
  gcloud container node-pools describe --project=${project_id} --cluster=${cluster_name} ${node_pool} --zone=${zone} | grep -w 'machineType' | tr -s '\t' ' ' | rev | cut -d' ' -f1 | rev
}

function getNumNodesInNodePool() {
  local cluster=${1}
  local node_pool=${2}
  local zone=${3}
  gcloud container node-pools describe --project=${project_id} --cluster=${cluster_name} ${node_pool} --zone=${zone} | grep -w 'initialNodeCount' | tr -s '\t' ' ' | rev | cut -d' ' -f1 | rev
}

function getNumLocalSSDsPerNodeInNodePool() {
  local cluster=${1}
  local node_pool=${2}
  local zone=${3}
  gcloud container node-pools describe --project=${project_id} --cluster=${cluster_name} ${node_pool} --zone=${zone} | grep -w 'localSsdCount' | tr -s '\t' ' ' | rev | cut -d' ' -f1 | rev
}

function doesClusterExist() {
  local cluster_name=${1}
  gcloud container clusters list --project=${project_id} | grep -woq ${cluster_name}
}

# Create and set up (or reconfigure) a GKE cluster.
function ensureGkeCluster() {
  echo "Creating/updating cluster ${cluster_name} ..."
  if doesClusterExist ${cluster_name}; then
    existing_machine_type=$(getMachineTypeInNodePool ${cluster_name} ${node_pool} ${zone})
    if [ "${existing_machine_type}" != "${machine_type}" ] ; then
      echo "Internally changing machine-type from ${machine_type} to ${existing_machine_type} ..."
      machine_type=${existing_machine_type}
    fi
    cluster_updation_command="gcloud container clusters update ${cluster_name} --project=${project_id} --location=${zone}"
    ${cluster_updation_command} --workload-pool=${project_id}.svc.id.goog
    # Separating in two update calls as gcloud doesn't support updating these
    # two fields in a single call.
    if ${zonal}; then
      ${cluster_updation_command} --private-ipv6-google-access-type=bidirectional
    fi
  else
    # Create a new cluster
    cluster_creation_args="--project=${project_id} --zone ${zone} --workload-pool=${project_id}.svc.id.goog --machine-type ${machine_type} --image-type COS_CONTAINERD --num-nodes ${num_nodes} --ephemeral-storage-local-ssd count=${num_ssd} --network-performance-configs=total-egress-bandwidth-tier=TIER_1 --workload-metadata=GKE_METADATA --enable-gvnic"
    if ${zonal}; then
      cluster_creation_args+=" --private-ipv6-google-access-type=bidirectional"
    fi
    gcloud container clusters create ${cluster_name} ${cluster_creation_args}
  fi
}

function ensureRequiredNodePoolConfiguration() {
  echo "Creating/updating node-pool ${node_pool} ..."
  function createNodePool() { createNewNodePool ${cluster_name} ${zone} ${node_pool} ${machine_type} ${num_nodes} ${num_ssd}; }
  function deleteNodePool() { deleteExistingNodePool ${cluster_name} ${zone} ${node_pool}; }
  function recreateNodePool() { deleteNodePool && createNodePool; }

  if doesNodePoolExist ${cluster_name} ${zone} ${node_pool}; then

    existing_machine_type=$(getMachineTypeInNodePool ${cluster_name} ${node_pool} ${zone})
    num_existing_localssd_per_node=$(getNumLocalSSDsPerNodeInNodePool ${cluster_name} ${node_pool} ${zone})
    num_existing_nodes=$(getNumNodesInNodePool ${cluster_name} ${node_pool} ${zone})

    if [ "${existing_machine_type}" != "${machine_type}" ]; then
      echo "cluster "${node_pool}" exists, but machine-type differs, so deleting and re-creating the node-pool."
      recreateNodePool
    elif [ ${num_existing_nodes} -ne ${num_nodes} ]; then
      echo "cluster "${node_pool}" exists, but number of nodes differs, so resizing the node-pool."
      resizeExistingNodePool ${cluster_name} ${zone} ${node_pool} ${num_nodes}
    elif [ ${num_existing_localssd_per_node} -ne ${num_ssd} ]; then
      echo "cluster "${node_pool}" exists, but number of SSDs differs, so deleting and re-creating the node-pool"
      recreateNodePool
    else
      echo "cluster "${node_pool}" already exists"
    fi
  else
    createNodePool
  fi
}

function enableManagedCsiDriver() {
  printf "\nEnabling csi add-on ...\n\n"
  gcloud -q container clusters update ${cluster_name} \
    --project=${project_id} \
    --update-addons GcsFuseCsiDriver=ENABLED \
    --location=${zone}
}

function activateCluster() {
  printf "\nConfiguring cluster credentials ...\n\n"
  gcloud container clusters get-credentials ${cluster_name} --project=${project_id} --location=${zone}
  kubectl config current-context
}

function createKubernetesServiceAccountForCluster() {
  printf "\nCreating namespace and KSA ...\n\n"
  log="$(kubectl create namespace ${appnamespace} 2>&1)" || [[ "$log" == *"already exists"* ]]
  log="$(kubectl create serviceaccount ${ksa} --namespace ${appnamespace} 2>&1)" || [[ "$log" == *"already exists"* ]]
  kubectl config set-context --current --namespace=${appnamespace}
  # Validate it
  kubectl config view --minify | grep namespace:
}

function ensureGcsfuseToolsCode() {
  printf "\nEnsuring we have gcsfuse-tools code ...\n\n\n"
  # clone gcsfuse-tools repo if needed
  if ! test -d "${gcsfuse_tools_src_dir}"; then
    cd $(dirname "${gcsfuse_tools_src_dir}") && git clone ${gcsfuse_tools_github_path} && cd "${gcsfuse_tools_src_dir}" && git switch ${gcsfuse_tools_branch} && cd - >/dev/null && cd - >/dev/null
  elif ${force_update_gcsfuse_tools_code}; then
    cd ${gcsfuse_tools_src_dir} && git fetch --all && git reset --hard origin/${gcsfuse_tools_branch} && cd - >/dev/null
  fi

  test -d "${gke_testing_dir}" || (exitWithError "${gke_testing_dir} does not exist" )
}

function ensureGcsfuseCode() {
  printf "\nEnsuring we have gcsfuse code ...\n\n\n"
  if test -z "${gcsfuse_src_dir}"; then
    export gcsfuse_src_dir="${src_dir}"/gcsfuse
  fi
  if test -z "${force_update_gcsfuse_code}"; then
    export force_update_gcsfuse_code=${DEFAULT_FORCE_UPDATE_GCSFUSE_CODE}
  fi

  # clone gcsfuse code if needed
  if ! test -d "${gcsfuse_src_dir}"; then
    mkdir -pv $(dirname "${gcsfuse_src_dir}") && cd $(dirname "${gcsfuse_src_dir}") && git clone ${gcsfuse_github_path} && cd "${gcsfuse_src_dir}" && git switch ${gcsfuse_branch} && cd - >/dev/null && cd - >/dev/null
  elif ${force_update_gcsfuse_code}; then
    cd ${gcsfuse_src_dir} && git fetch --all && git reset --hard origin/${gcsfuse_branch} && cd - >/dev/null
  fi
}

function ensureGcsFuseCsiDriverCode() {
  printf "\nEnsuring we have gcs-fuse-csi-driver code ...\n\n"
  if test -z "${csi_src_dir}"; then
    export csi_src_dir="${src_dir}"/gcs-fuse-csi-driver
  fi
  # clone csi-driver code if needed
  if ! test -d "${csi_src_dir}"; then
    mkdir -pv $(dirname "${csi_src_dir}") && cd $(dirname "${csi_src_dir}") && git clone ${csi_driver_github_path} && cd "${csi_src_dir}" && git switch ${csi_driver_branch} && cd - >/dev/null && cd - >/dev/null
  fi
}

uuid() {
  echo $(uuidgen) | sed -e "s/\-//g" ;
}

function createCustomCsiDriverIfNeeded() {
  if ${use_custom_csi_driver} && test -z "${applied_custom_csi_driver}"; then
    printf "\nCreating a new custom CSI driver ...\n\n"

    # Create a bucket (if needed) for storing GCSFuse binaries.
    if test -z "${package_bucket}"; then
      package_bucket=${project_id}-${cluster_name}-gcsfuse-bin
      package_bucket=${package_bucket/google/}
    fi
    if [[ ${#package_bucket} -gt 63 ]] ; then
      echoerror "package_bucket \"${package_bucket}\" is too long (should be <= 63)"
      return 1
    fi
    # If package_bucket does not already exist, create it.
    if (! (gcloud storage buckets list --project=${project_id} | grep -wqo ${package_bucket}) ); then
      region=$(echo ${zone} | rev | cut -d- -f2- | rev)
      gcloud storage buckets create gs://${package_bucket} --project=${project_id} --location=${region}
    fi

    # Ensure that gcsfuse source code is available by now for building a binary
    # from it.
    ensureGcsfuseCode

    # Build new gcsfuse binaries.
    printf "\nBuilding a new GCSFuse binary from ${gcsfuse_src_dir} ...\n\n"
    cd "${gcsfuse_src_dir}"
    rm -rfv ./bin ./sbin
    GOOS=linux GOARCH=amd64 go run tools/build_gcsfuse/main.go . . v3
    # Copy the binary to a GCS bucket for csi driver build.
    gcloud storage -q cp ./bin/gcsfuse gs://${package_bucket}/linux/amd64/
    gcloud storage -q cp gs://${package_bucket}/linux/amd64/gcsfuse gs://${package_bucket}/linux/arm64/ # needed as build on arm64 doesn't work on cloudtop.
    # clean-up
    rm -rfv "${gcsfuse_src_dir}"/bin "${gcsfuse_src_dir}"/sbin
    cd - >/dev/null

    # Build and install csi driver
    ensureGcsFuseCsiDriverCode
    cd "${csi_src_dir}"
    make generate-spec-yaml
    printf "\nBuilding a new custom CSI driver using the above GCSFuse binary ...\n\n"
    registry=gcr.io/${project_id}/${USER}/${cluster_name}
    if ! which uuidgen; then
      # try to install uuidgen
      sudo apt-get update && sudo apt-get install -y uuid-runtime
      # confirm that it got installed.
      which uuidgen
    fi
    stagingversion=$(uuid)
    make build-image-and-push-multi-arch REGISTRY=${registry} GCSFUSE_PATH=gs://${package_bucket} STAGINGVERSION=${stagingversion}

    readonly subregistry=gcs-fuse-csi-driver-sidecar-mounter
    applied_custom_csi_driver=${registry}/${subregistry}:${stagingversion}
    printf "\n\nCreated custom csi driver \" ${applied_custom_csi_driver} \" . To use it in future runs, please pass environment variable \" custom_csi_driver=${applied_custom_csi_driver} \" .\n\n"

    # Verify that the csi-driver image is a good image to use..
    printf "\nVerifying that ${applied_custom_csi_driver} is a valid GCSFuse csi driver image ...\n\n"
    sleep 30
    verify_csi_driver_image ${applied_custom_csi_driver}

    cd - >/dev/null
  fi
}

function deleteAllHelmCharts() {
  printf "Deleting all existing helm charts ...\n\n"
  helm ls --namespace=${appnamespace} | tr -s '\t' ' ' | cut -d' ' -f1 | tail -n +2 | while read helmchart; do helm uninstall ${helmchart} --namespace=${appnamespace}; done
}

function deleteAllPods() {
  deleteAllHelmCharts

  printf "Deleting all existing pods ...\n\n"
  kubectl get pods --namespace=${appnamespace}  | tail -n +2 | cut -d' ' -f1 | while read podname; do kubectl delete pods/${podname} --namespace=${appnamespace} --grace-period=0 --force || true; done
}

function deployAllFioHelmCharts() {
  printf "\nDeploying all fio helm charts ...\n\n"
  cd "${gke_testing_dir}"/examples/fio
  python3 ./run_tests.py --workload-config "${workload_config}" --experiment-id ${experiment_id} --machine-type="${machine_type}" --project-id=${project_id} --project-number=${project_number} --namespace=${appnamespace} --ksa=${ksa} --custom-csi-driver=${applied_custom_csi_driver}
  cd - >/dev/null
}

function deployAllDlioHelmCharts() {
  printf "\nDeploying all dlio helm charts ...\n\n"
  cd "${gke_testing_dir}"/examples/dlio
  python3 ./run_tests.py --workload-config "${workload_config}" --experiment-id ${experiment_id} --machine-type="${machine_type}" --project-id=${project_id} --project-number=${project_number} --namespace=${appnamespace} --ksa=${ksa} --custom-csi-driver=${applied_custom_csi_driver}

  cd - >/dev/null
}

function waitTillAllPodsComplete() {
  start_epoch=$(date +%s)
  printf "\nScanning and waiting till all pods either complete/fail, or time out (start-time epoch = ${start_epoch} seconds, timeout duration = ${pod_timeout_in_seconds} seconds) ...\n\n"
  while true; do
    cur_epoch=$(date +%s)
    time_till_timeout=$((start_epoch+pod_timeout_in_seconds-cur_epoch))
    if [[ ${time_till_timeout} -lt 0 ]]; then
      echoerror printf "\nPod-run timed out!\n\n"
      printf "Clearing all pods created in this run...\n"
      deleteAllPods
      exitWithFailure
    fi
    printf "Checking pods status at ${cur_epoch} seconds:\n"
    printf " -----------------------------------------\n"
    podslist="$(kubectl get pods --namespace=${appnamespace} -o wide)"
    echo "${podslist}"
    num_completed_pods=$(echo "${podslist}" | tail -n +2 | grep -i 'completed\|succeeded' | wc -l)
    if [ ${num_completed_pods} -gt 0 ]; then
      printf ${num_completed_pods}" pod(s) have completed.\n"
    fi
    num_noncompleted_pods=$(echo "${podslist}" | tail -n +2 | grep -i -v 'completed\|succeeded\|fail\|error\|unknown\|oomkilled' | wc -l)
    num_failed_pods=$(echo "${podslist}" | tail -n +2 | grep -i 'failed\|oomkilled\|error\|unknown' | wc -l)
    if [ ${num_failed_pods} -gt 0 ]; then
      printf ${num_failed_pods}" pod(s) have failed.\n\n"
    fi
    num_unknown_pods=$(echo "${podslist}" | tail -n +2 | grep -i 'unknown' | wc -l)
    if [ ${num_unknown_pods} -gt 0 ]; then
      printf ${num_unknown_pods}" pod(s) have status 'Unknown'.\n\n"
    fi
    if [ ${num_noncompleted_pods} -eq 0 ]; then
      printf "\nAll pods have completed.\n\n"
      break
    else
      message="\n${num_noncompleted_pods} pod(s) is/are still pending/running (time till timeout=${time_till_timeout} seconds). Will check again in "${pod_wait_time_in_seconds}" seconds. Sleeping for now.\n\n"
      message+="\nYou can take a break too if you want. Just kill this run and connect back to it later, for fetching and parsing outputs, using the following command: \n\n"
      message+="   only_parse=true experiment_id=${experiment_id} project_id=${project_id} project_number=${project_number} zone=${zone} machine_type=${machine_type}"
      message+=" use_custom_csi_driver=${use_custom_csi_driver}"
      if test -n "${custom_csi_driver}"; then
        message+=" custom_csi_driver=${custom_csi_driver}"
      fi
      message+=" gcsfuse_tools_src_dir=\"${gcsfuse_tools_src_dir}\" "
      if test -n "${gcsfuse_src_dir}"; then
        message+=" gcsfuse_src_dir=\"${gcsfuse_src_dir}\" "
      fi
      if test -d "${csi_src_dir}"; then
        message+="csi_src_dir=\"${csi_src_dir}\" "
      fi
      message+=" zonal=${zonal} "
      message+="pod_wait_time_in_seconds=${pod_wait_time_in_seconds} pod_timeout_in_seconds=${pod_timeout_in_seconds} workload_config=\"${workload_config}\" cluster_name=${cluster_name} output_dir=\"${output_dir}\" $0 \n"
      message+="\nbut remember that this will reset the start-timer for pod timeout.\n\n"
      message+="\nTo ssh to any specific pod, use the following command: \n"
      message+="  gcloud container clusters get-credentials ${cluster_name} --location=${zone}\n"
      message+="  kubectl config set-context --current --namespace=${appnamespace}\n"
      message+="  kubectl exec -it pods/<podname> [-c {gke-gcsfuse-sidecar|fio-tester|dlio-tester}] --namespace=${appnamespace} -- /bin/bash \n"
      message+="\nTo view cpu/memory usage of different pods/containers: \n"
      message+="  kubectl top pod [<podname>] --namespace=${appnamespace} [--containers] \n"
      message+="\nTo view the latest status of all the pods in this cluster/namespace: \n"
      message+="  kubectl get pods --namespace=${appnamespace} [-o wide] [--watch] \n"
      message+="\nTo output the configuration of all or one of the pods in this cluster/namespace (useful for debugging): \n"
      message+="  kubectl get [pods or pods/<podname>] --namespace=${appnamespace} -o yaml \n"
      printf "${message}\n\n\n"
    fi
    sleep ${pod_wait_time_in_seconds}
    unset podslist # necessary to update the value of podslist every iteration
  done
}

# Download all the fio workload outputs for the current experiment-id from the
# given bucket and file-size.
function downloadFioOutputsFromBucket() {
  local bucket=$1
  local mountpath=$2/${bucket}-mount

  mkdir -p $mountpath
  fusermount -uz $mountpath 2>/dev/null || true
  echo "Searching for FIO outputs for experiment ${experiment_id} in gs://${bucket} ..."

  cd $gcsfuse_tools_src_dir
  if ! go run $gcsfuse_tools_src_dir --implicit-dirs --o ro $bucket $mountpath > /dev/null ; then
    # If fails to mount this bucket,
    # Return to original directory before exiting..
    cd - >/dev/null

    exitWithError "Failed to mount bucket ${bucket} to ${mountpath}."
  fi

  # Return to original directory.
  cd - >/dev/null

  # If the given bucket has the fio outputs for the given experiment-id, then
  # copy/download them locally to the appropriate folder.
  src_dir="${mountpath}/fio-output/${experiment_id}"
  dst_dir="${gcsfuse_tools_src_dir}/testing_on_gke/bin/fio-logs/${experiment_id}/${bucket}"
  if test -d "${src_dir}" ; then
    mkdir -p "${dst_dir}"
    echo "Copying all files from \"${src_dir}\" to \"${dst_dir}/\" ... "
    cp -rfu "${src_dir}"/* "${dst_dir}"/
  fi

  fusermount -uz "${mountpath}" || true
  rm -rf "${mountpath}"
}

function downloadFioOutputsFromAllBucketsInWorkloadConfig() {
  local mountpath=$(realpath mounted)
  # Using jquery, find out all the relevant buckets for non-disabled fio
  # workloads in the workload-config file and download fio outputs for them all.
  cat ${workload_config} | jq 'select(.TestConfig.workloadConfig.workloads[].fioWorkload != null)' | jq -r '.TestConfig.workloadConfig.workloads[] | [.bucket] | @csv' | grep -v " " | sort | uniq | while read bucket; do
    bucket=$(echo ${bucket} | tr -d \" )
    if [[ "${bucket}" != "" ]]; then
       downloadFioOutputsFromBucket ${bucket} "${mountpath}"
    fi
  done
  rm -rf ${mountpath}
}

function areThereAnyDLIOWorkloads() {
  lines=$(cat ${workload_config} | jq 'select(.TestConfig.workloadConfig.workloads[].dlioWorkload != null)' | jq -r '.TestConfig.workloadConfig.workloads[] | [.bucket, .dlioWorkload.numFilesTrain, .dlioWorkload.recordLength] | @csv' | grep -v " " | sort | uniq)
  while read bucket_numFilesTrain_recordLength_combo; do
    workload_bucket=$(echo ${bucket_numFilesTrain_recordLength_combo} | cut -d, -f1 | tr -d \")
    workload_numFileTrain=$(echo ${bucket_numFilesTrain_recordLength_combo} | cut -d, -f2 | tr -d \")
    workload_recordLength=$(echo ${bucket_numFilesTrain_recordLength_combo} | cut -d, -f3 | tr -d \")
    if [[ "${workload_bucket}" != "" && "${workload_numFileTrain}" != "" && "${workload_recordLength}" != "" ]]; then
      return 0
    fi
  done <<< "${lines}" # It's necessary to pass lines this way to while
  # to avoid creating a subshell for while-execution, to
  # ensure that the above return statement works in the same shell.

  return 1
}

function fetchAndParseFioOutputs() {
  printf "\nFetching and parsing fio outputs ...\n\n"
  cd "${gke_testing_dir}"/examples/fio
  parse_logs_args="--project-number=${project_number} --workload-config ${workload_config} --experiment-id ${experiment_id} --output-file ${output_dir}/fio/output.csv --project-id=${project_id} --cluster-name=${cluster_name} --namespace-name=${appnamespace} --bq-project-id=${DEFAULT_BQ_PROJECT_ID} --bq-dataset-id=${DEFAULT_BQ_DATASET_ID} --bq-table-id=${DEFAULT_BQ_TABLE_ID}"
  if ${zonal}; then
    #  Download fio outputs from all buckets using gcsfuse because zonal buckets don't work with gcloud storage cp.
    printf "\nDownloading all fio outputs using gcsfuse mount as there are zonal buckets involved ...\n\n"
    downloadFioOutputsFromAllBucketsInWorkloadConfig

    python3 parse_logs.py ${parse_logs_args} --predownloaded-output-files
  else
    python3 parse_logs.py ${parse_logs_args}
  fi
  cd - >/dev/null
}

function fetchAndParseDlioOutputs() {
  printf "\nFetching and parsing dlio outputs ...\n\n"
  cd "${gke_testing_dir}"/examples/dlio
  python3 parse_logs.py --project-number=${project_number} --workload-config "${workload_config}" --experiment-id ${experiment_id} --output-file "${output_dir}"/dlio/output.csv --project-id=${project_id} --cluster-name=${cluster_name} --namespace-name=${appnamespace}
  cd - >/dev/null
}

# prep
printRunParameters
installDependencies

# if only_parse is false, then
if ! ${only_parse} ; then
  validateMachineConfig ${machine_type} ${num_nodes} ${num_ssd}

  if ${zonal} && $(areThereAnyDLIOWorkloads); then
    exitWithError "DLIO workloads are not supported with zonal buckets as of now."
  fi

  # GCP configuration
  ensureGcpAuthsAndConfig
  ensureGkeCluster
  # ensureRequiredNodePoolConfiguration
  enableManagedCsiDriver
  activateCluster
  createKubernetesServiceAccountForCluster

  # GCSFuse-tools source code
  ensureGcsfuseToolsCode

  # GCP/GKE configuration dependent on GCSFuse/CSI driver source code
  createCustomCsiDriverIfNeeded

  # Run latest workload configuration
  deleteAllPods
  deployAllFioHelmCharts
  deployAllDlioHelmCharts
fi

# monitor pods
waitTillAllPodsComplete

# clean-up after run
deleteAllPods

# parse outputs
fetchAndParseFioOutputs
fetchAndParseDlioOutputs

if test -z "${custom_csi_driver}" && test -n "${applied_custom_csi_driver}"; then
  printf "\nTo reuse this custom CSI driver in future runs, pass environment variable \" custom_csi_driver=${applied_custom_csi_driver} \" .\n\n"
fi
