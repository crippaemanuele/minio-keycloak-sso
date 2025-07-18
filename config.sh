#!/bin/bash

# Aggiunge i repository Helm necessari e aggiorna la cache
prerequisiti() {
  helm repo add jetstack https://charts.jetstack.io
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo add opa-kube-mgmt https://open-policy-agent.github.io/kube-mgmt/charts
  helm repo add minio-operator https://operator.min.io
  helm repo update
  #cd Projects/minio-keycloak-sso/
  sleep 3
}

# Avvia Minikube, abilita ingress e crea i namespace necessari
inizializzazione() {
  echo "Eseguendo inizializzazione..."
  minikube start --driver=docker --cpus=3 --memory=6144
  minikube addons enable ingress
  for ns in cert-manager keycloak minio-operator opa tenant-1; do
    kubectl create ns $ns --dry-run=client -o yaml | kubectl apply -f - # crea namespace se non esiste
    kubectl label namespace $ns create-ca-bundle=true --overwrite=true   # aggiunge label per trust-manager
  done
  sleep 5
}

# Installa cert-manager e trust-manager, applica il ClusterIssuer
configura_cert_manager() {
  echo "Configurando Cert-Manager..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true # installa CRDs
  helm upgrade --install trust-manager jetstack/trust-manager \
    --namespace cert-manager \
    -f trust-manager/values.yaml
  kubectl apply -f tls/selfsigned-root-clusterissuer.yaml # ClusterIssuer per CA self-signed
  sleep 10
}

# Applica e gestisce i certificati per Keycloak, OPA, MinIO Operator e Tenant
configura_certificati() {
  # --- KEYCLOAK ---
  kubectl apply -f tls/keycloak/keycloak-ca-certificate.yaml
  kubectl apply -f tls/keycloak/keycloak-ca-issuer.yaml
  kubectl wait --for=create secret keycloak-ca-tls -n keycloak # attende la creazione del secret
  kubectl get secrets -n keycloak keycloak-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/keycloak-ca.crt
  kubectl create secret generic keycloak-ca-tls --from-file=certs/keycloak-ca.crt -n cert-manager

  # --- OPA ---
  kubectl apply -f tls/opa/opa-ca-certificate.yaml
  kubectl apply -f tls/opa/opa-ca-issuer.yaml
  kubectl wait --for=create secret opa-ca-tls -n opa
  kubectl get secrets -n opa opa-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/opa-ca.crt
  kubectl create secret generic opa-ca-tls --from-file=certs/opa-ca.crt -n cert-manager

  # --- MINIO OPERATOR ---
  kubectl apply -f tls/minio/operator-ca-tls-secret.yaml
  kubectl apply -f tls/minio/operator-ca-issuer.yaml
  kubectl apply -f tls/minio/sts-tls-certificate.yaml

  # --- MINIO TENANT ---
  kubectl apply -f tls/minio/tenant-1-ca-certificate.yaml
  kubectl apply -f tls/minio/tenant-1-ca-issuer.yaml
  kubectl apply -f tls/minio/tenant-1-minio-certificate.yaml
  kubectl wait --for=create secret tenant-1-ca-tls -n tenant-1
  kubectl get secrets -n tenant-1 tenant-1-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/minio-ca.crt
  kubectl create secret generic tenant-1-ca-tls --from-file=certs/minio-ca.crt -n cert-manager

  # --- ESTRAZIONE E PATCH DEI CERTIFICATI ---
  mkdir -p ./tmp
  kubectl wait --for=create secret myminio-tls -n tenant-1
  kubectl get secret myminio-tls -n tenant-1 -o jsonpath='{.data.tls\.crt}' | base64 -d > tmp/m_public.crt
  kubectl get secret myminio-tls -n tenant-1 -o jsonpath='{.data.tls\.key}' | base64 -d > tmp/m_private.key
  kubectl create secret generic myminio-tls-custom --from-file=public.crt=tmp/m_public.crt --from-file=private.key=tmp/m_private.key -n tenant-1
  kubectl patch secret myminio-tls -n tenant-1 --type='json' -p='[
    {"op": "add", "path": "/data/public.crt", "value":"'"$(cat tmp/m_public.crt | base64 -w 0)"'"},
    {"op": "add", "path": "/data/private.key", "value":"'"$(cat tmp/m_private.key | base64 -w 0)"'"}
  ]'
  rm -rf ./tmp
  sleep 30

  # --- BUNDLE TRUST MANAGER ---
  kubectl create -f trust-manager/bundle.yaml
  sleep 30
}

# Installa Keycloak tramite Helm e attende che sia pronto
configura_keycloak() {
  echo "Configurando Keycloak..."
  helm upgrade --install keycloak bitnami/keycloak \
    --namespace keycloak --create-namespace \
    -f keycloak/values.yaml
  KEYCLOAK_PASSWORD=$(kubectl -n keycloak get secret keycloak -o jsonpath='{.data.admin-password}' | base64 -d) # salva la password admin
  sleep 30
}

# Installa OPA, applica le policy e configura l'ingress
configura_opa() {
  echo "Configurando OPA..."
  # Cicla su tutti i file .rego nella cartella opa/policies
  for policy in opa/policies/*.rego; do
    policy_name=$(basename "$policy" .rego) # estrae il nome senza estensione
    kubectl create configmap "$policy_name" --from-file=main="$policy" -n opa --dry-run=client -o yaml | kubectl apply -f -
    kubectl label configmap "$policy_name" openpolicyagent.org/policy=rego -n opa --overwrite
    kubectl wait --for=create configMap $policy_name -n opa
  done
  kubectl wait --for=create secret opa-opa-kube-mgmt-cert -n opa
  helm upgrade --install opa opa-kube-mgmt/opa-kube-mgmt \
    --namespace opa --create-namespace \
    -f opa/values.yaml
  kubectl apply -f opa/ingress.yaml # espone OPA tramite ingress
  sleep 30
}

# Installa MinIO Operator tramite Helm
configura_minio_operator() {
  echo "Configurando MinIO Operator..."
  helm upgrade --install operator minio-operator/operator \
    --namespace minio-operator --create-namespace \
    -f minio/o-values.yaml
  sleep 30
}

# Installa il tenant MinIO e attende che i pod siano pronti
configura_tenant_minio() {
  kubectl wait -n keycloak --for=condition=Ready pod/keycloak-0 --timeout=300s   # attende che Keycloak sia pronto
  kubectl wait pod -n opa -l app=opa-opa-kube-mgmt --for=condition=Ready --timeout=60s # attende che OPA sia pronto
  echo "Configurando il tenant di MinIO..."
  helm upgrade --install myminio minio-operator/tenant \
    --namespace tenant-1 --create-namespace \
    -f minio/t-values.yaml
  sleep 30
}

# Rimuove pod falliti o completati e mostra info di accesso
pulizia() {
  echo "Pulendo il cluster..."
  kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name' --no-headers | while read ns name; do
    kubectl delete pod "$name" -n "$ns"
  done
  kubectl get pods --all-namespaces --field-selector=status.phase=Succeeded -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name' --no-headers | while read ns name; do
    kubectl delete pod "$name" -n "$ns"
  done
  echo "Tutte le configurazioni sono state completate con successo!"
  echo "Per accedere a Keycloak, utilizza l'URL: https://keycloak.local"
  echo "Password di Keycloak: $KEYCLOAK_PASSWORD"
  echo "Per accedere a MinIO, utilizza l'URL: https://minio.local"
  echo "Per accedere a OPA, utilizza l'URL: https://opa.local"
}

# Esecuzione sequenziale delle funzioni principali
prerequisiti
inizializzazione
configura_cert_manager
configura_certificati
configura_keycloak
configura_opa
configura_minio_operator
configura_tenant_minio
pulizia
