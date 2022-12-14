#!/usr/bin/env bash

set -o errexit

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PARENT_DIR=`dirname $SCRIPT_DIR`

# mirror kustomize-controller build options
kustomize_flags=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"


find $PARENT_DIR -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
  do
    if [[ "$file" == *"/templates/"* ]]; then
      echo "INFO - Skip $file"
    else
      echo "INFO - Validating $file"
      yq e 'true' "$file" > /dev/null
    fi
done

find $PARENT_DIR -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
  do
    echo "INFO - Validating kustomization ${file/%$kustomize_config}"
    kustomize build "${file/%$kustomize_config}" "${kustomize_flags[@]}" | \
      kubeconform --ignore-missing-schemas "${kubeconform_config[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done