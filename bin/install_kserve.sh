#!/bin/bash

set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd "$DIR" || exit

# import configs
source ${DIR}/../tools/kserve/config.sh

function wait_for_deployment() {
    echo -n "waiting for all pods running underneath of $1 deployment"

    STILL_WAITING=true
    while $STILL_WAITING; do
        STILL_WAITING=false
        PODS=$(kubectl get pods -n $2 -l app=$1 2>/dev/null | grep $1 | awk '{print $1}')
        for POD in ${PODS}; do
            READY=$(kubectl get pod ${POD} -n $2 2>/dev/null | grep $1 | awk '{print $2}')
            DESIRED_STATE=$(echo ${READY} | cut -d/ -f 1)
            CURRENT_STATE=$(echo ${READY} | cut -d/ -f 2)
            if [ $DESIRED_STATE -ne $CURRENT_STATE ]; then
                STILL_WAITING=true
                sleep 1
                echo -n "."
            fi
        done
    done

    echo
}

function wait_for_statefulset() {
    echo -n "waiting for $1 statefulset to run"

    STILL_WAITING=true
    while $STILL_WAITING; do
        STILL_WAITING=false
        READYS=$(kubectl get statefulset -n $2 2>/dev/null | grep $1 | awk '{print $2}')
        for READY in ${READYS}; do
            DESIRED_STATE=$(echo ${READY} | cut -d/ -f 1)
            CURRENT_STATE=$(echo ${READY} | cut -d/ -f 2)
            if [ $DESIRED_STATE -ne $CURRENT_STATE ]; then
                STILL_WAITING=true
                sleep 1
                echo -n "."
            fi
        done
    done

    echo
}

########## Install Cert Manager ##########
IS_CERT_INSTALLED=$(kubectl get crd certificaterequests.cert-manager.io 2>&1 | grep "Error from server (NotFound)" | wc -l)
if [ "$IS_CERT_INSTALLED" -eq 1 ]; then
    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml
    CERT_MANAGER_DEPLOYMENTS="cert-manager-cainjector cert-manager-webhook cert-manager"
    for CERT_MANAGER_DEPLOYMENT in $CERT_MANAGER_DEPLOYMENTS; do
        wait_for_deployment $CERT_MANAGER_DEPLOYMENT "cert-manager"
    done
else
    echo "skip cert-manager install"
fi

# temp dir
WORK_DIR=$(mktemp -d -p "${DIR}")
if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
    echo "Could not create temp dir"
    exit 1
fi
cd "${WORK_DIR}"

# deletes the temp directory
function cleanup() {
    rm -rf "$WORK_DIR"
    echo "Deleted temp working directory $WORK_DIR"
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT

########## Install Istio ##########
ISTIO_OPTIONS="ISTIO_VERSION TARGET_ARCH"
for ISTIO_OPTION in $ISTIO_OPTIONS; do
    if [ -z "${!ISTIO_OPTION}" ]; then
        echo "$ISTIO_OPTION is empty"
        exit 1
    fi
done

curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION TARGET_ARCH=$TARGET_ARCH sh -

pushd "./istio-${ISTIO_VERSION}/bin"
PRECHECK_RESULT=$(./istioctl x precheck | grep "Install Pre-Check passed!" | wc -l)
if [ "$PRECHECK_RESULT" -ne 1 ]; then
    echo "istio x precheck failed"
    FAIL_REASON=$(./istioctl x precheck | grep "already installed in namespace" | wc -l)
    if [ "$FAIL_REASON" -ne 1 ]; then
        read -p "Force install istio? (Y/N): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            echo "install istio forcingly"
            ./istioctl install --force -y -f "${DIR}/../tools/kserve/istio-minimal-operator.yaml"
        else
            echo "do not install istio forcingly, bye bye~"
            exit 1
        fi
    else
        echo "unhandled precheck fail"
        exit 1
    fi
else
    ./istioctl install -y -f "${DIR}/../tools/kserve/istio-minimal-operator.yaml"
fi
popd

ISTIO_DEPLOYMENTS="istiod cluster-local-gateway istio-ingressgateway"
for ISTIO_DEPLOYMENTS in $ISTIO_DEPLOYMENTS; do
    wait_for_deployment $ISTIO_DEPLOYMENTS "istio-system"
done

########## Install Knative ##########
kubectl apply -f https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml
KNATIVE_CORE_DEPLOYMENTS="activator autoscaler controller webhook"
for KNATIVE_DEPLOYMENT in $KNATIVE_CORE_DEPLOYMENTS; do
    wait_for_deployment $KNATIVE_DEPLOYMENT "knative-serving"
done

kubectl apply -f https://github.com/knative/net-istio/releases/download/${KNATIVE_VERSION}/release.yaml

KNATIVE_REL_DEPLOYMENTS="networking-istio istio-webhook"
for KNATIVE_DEPLOYMENT in $KNATIVE_REL_DEPLOYMENTS; do
    wait_for_deployment $KNATIVE_DEPLOYMENT "knative-serving"
done

function rpt() {
    set +e
    CMD="kubectl apply -f ${DIR}/../tools/kserve/cert-manager-test.yaml"
    echo "Start cert-manager testing, ignore error statements a seconds"
    until $CMD; do
        sleep 1
    done
    set -e
}
rpt
kubectl delete -f "${DIR}/../tools/kserve/cert-manager-test.yaml"

IS_KSERVE_INSTALLED=$(kubectl get crd inferenceservices.serving.kserve.io 2>&1 | grep "Error from server (NotFound)" | wc -l)
if [ "$IS_KSERVE_INSTALLED" -eq 1 ]; then
    kubectl apply -f https://raw.githubusercontent.com/kserve/kserve/master/install/${KSERVE_VERSION}/kserve.yaml
    KSERVE_STATEFULSETS="kserve-controller-manager"
    for KSERVE_STATEFULSET in $KSERVE_STATEFULSETS; do
        wait_for_statefulset $KSERVE_STATEFULSET "kserve-system"
    done
else
    echo "skip kserve install"
fi
