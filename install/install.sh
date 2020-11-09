#! /bin/bash

PIPELINE_NS=mq-pipeline
PIPELINE_SA=mqpipeline
MQ_NS=cp4i

GIT_SECRET_NAME=user-at-github

# Insert your Git Access Token below
GIT_TOKEN=<paste git token here and remove brackets>

# Insert your Git UserName here
GIT_USERNAME=<paste github username here and remove brackets>

# Create the pipeline namespace
kubectl create ns $PIPELINE_NS

# Change to the new namespace
oc project $PIPELINE_NS

# install tekton pipelines
# kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# # install tekton triggers
# kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

# create the git secret
oc secret new-basicauth $GIT_SECRET_NAME --username=$GIT_USERNAME --password $GIT_TOKEN

# annotate the secret
kubectl annotate secret $GIT_SECRET_NAME tekton.dev/git-0=github.com

# create serviceaccount to run the pipeline and associate the git secret with the serviceaccount
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $PIPELINE_SA
secrets:
- name: $GIT_SECRET_NAME
EOF

# Create the ClusterRole
cat << EOF | kubectl apply -f -
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: tekton-pipelines-admin
rules:
# Permissions for every EventListener deployment to function
- apiGroups: ["triggers.tekton.dev"]
  resources: ["eventlisteners", "triggerbindings", "triggertemplates"]
  verbs: ["get"]
- apiGroups: [""]
  # secrets are only needed for Github/Gitlab interceptors, serviceaccounts only for per trigger authorization
  resources: ["configmaps", "secrets", "serviceaccounts"]
  verbs: ["get", "list", "watch"]
# Permissions to create resources in associated TriggerTemplates
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "pipelineresources", "taskruns"]
  verbs: ["create"]
EOF

# Create these ClusterRoleBindings
oc create clusterrolebinding mqpipelinetektonpipelinesadminbinding --clusterrole=tekton-pipelines-admin --serviceaccount=$PIPELINE_NS:$PIPELINE_SA
oc create clusterrolebinding mqpipelinetektontriggersadminbinding --clusterrole=tekton-triggers-admin --serviceaccount=$PIPELINE_NS:$PIPELINE_SA

oc create clusterrolebinding mqpipelinepullerbinding --clusterrole=system:image-puller --serviceaccount=$PIPELINE_NS:$PIPELINE_SA
oc create clusterrolebinding mqpipelinebuilderinding --clusterrole=system:image-builder --serviceaccount=$PIPELINE_NS:$PIPELINE_SA

oc create clusterrolebinding mqpipelineqmeditbinding --clusterrole=queuemanagers.mq.ibm.com-v1beta1-edit --serviceaccount=$PIPELINE_NS:$PIPELINE_SA
oc create clusterrolebinding mqpipelineqmviewbinding --clusterrole=queuemanagers.mq.ibm.com-v1beta1-view --serviceaccount=$PIPELINE_NS:$PIPELINE_SA

oc create clusterrolebinding mqpipelineviewerbinding --clusterrole=view --serviceaccount=$PIPELINE_NS:$PIPELINE_SA

# Allow the serviceaccount to get secrets from any namespae

oc create clusterrole secretreader --verb=get --resource=secrets 
oc -n $MQ_NS create rolebinding secretreaderbinding --clusterrole=secretreader --serviceaccount=$PIPELINE_NS:$PIPELINE_SA

# Add the serviceaccount to privileged SecurityContextConstraint
oc adm policy add-scc-to-user privileged system:serviceaccount:$PIPELINE_NS:$PIPELINE_SA

# Add tekton resources
oc apply -f ./tekton/pipelines/
oc apply -f ./tekton/resources/
oc apply -f ./tekton/tasks/
oc apply -f ./tekton/triggers/

# Create route for webhook
cat << EOF | kubectl apply -f -

apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    app.kubernetes.io/managed-by: EventListener
    app.kubernetes.io/part-of: Triggers
    eventlistener: el-cicd-mq
  name: el-el-cicd-mq-hook-route
spec:
  port:
    targetPort: http-listener
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: el-el-cicd-mq
EOF