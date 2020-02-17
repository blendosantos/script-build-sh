#!/bin/bash
############################### PARAMETROS ###############################

# DOCS
# https://access.redhat.com/containers/?tab=support#/registry.access.redhat.com/jboss-webserver-3/webserver31-tomcat8-openshift
# https://access.redhat.com/documentation/en-us/red_hat_jboss_web_server/3.1/html-single/red_hat_jboss_web_server_for_openshift/index

# Display our environment
echo "========================================================================="
echo "Projeto Openshift Environment"
echo ""
oc project
oc whoami
oc version
echo ""
echo "========================================================================="
echo ""

### GERAIS ###

#Variável com o nome do projeto OpenShift onde será realizado o deploy da aplicação
read -p "Nome do Projeto Openshift (projeto-hml): " DEPLOY_PROJECT
if [ "x$DEPLOY_PROJECT" = "x" ]; then
    DEPLOY_PROJECT="projeto-hml"
fi

#Variável com o nome da aplicação a ser criada no OpenShift (nomes dos objetos OpenShift)
read -p "Nome da Aplicação Openshift (projeto): " APP_NAME
if [ "x$APP_NAME" = "x" ]; then
    APP_NAME="projeto"
fi

TIME_ZONE="America/Bahia"

# Nome do pacote WAR
read -p "Nome do pacote WAR (metadados.war): " DEPLOY_ARTIFACT
if [ "x$DEPLOY_ARTIFACT" = "x" ]; then
    DEPLOY_ARTIFACT=metadados.war
fi

### ROTAS ###

read -p "Rota Openshift (projeto.url.com.br): " ROUTE_HOSTNAME
if [ "x$ROUTE_HOSTNAME" = "x" ]; then
    ROUTE_HOSTNAME=projeto.url.com.br
fi

### LIMITE DE RECURSOS ###

read -p "Recursos do POD (memory=1024Mi,cpu=500m): " POD_RESOURCE_REQUEST
if [ "x$POD_RESOURCE_REQUEST" = "x" ]; then
    POD_RESOURCE_REQUEST=memory=1024Mi,cpu=500m
fi

read -p "Limite de Recursos do POD (memory=2048Mi,cpu=1000m): " POD_RESOURCE_LIMIT
if [ "x$POD_RESOURCE_LIMIT" = "x" ]; then
    POD_RESOURCE_LIMIT=memory=2048Mi,cpu=1000m
fi

read -p "Confirma o deploy? (s/n): " confirm && [[ $confirm == [sS] || $confirm == [yY] ]] || exit 1

##########################################################################

# Preparando o binário para deploy
mv $DEPLOY_ARTIFACT ROOT.war
# Limpa a pasta deployments
rm -rf deployments/
# Cria estrutura de deploy
mkdir deployments/
mv ROOT.war deployments/

# Garantindo as operações no projeto correto
oc project $DEPLOY_PROJECT

#Deletando TODOS os objetos já existentes que tenham o label "app=$APP_NAME"
oc delete all -l app=$APP_NAME -n $DEPLOY_PROJECT

#Criando aplicação no OpenShift
oc adm policy add-scc-to-user anyuid -z default
oc new-build openshift/jboss-webserver30-tomcat8-openshift:1.3 --name=$APP_NAME --binary=true
oc start-build $APP_NAME --from-dir=. --follow=true --wait=true
oc new-app $APP_NAME

#Zerando a quantidade de replicas visto que ainda existem outras configurações a serem feitas
oc scale --replicas=0 dc/$APP_NAME -n $DEPLOY_PROJECT

#Configurando recursos disponíves para o POD da aplicação
oc set resources dc/$APP_NAME --requests=$POD_RESOURCE_REQUEST --limits=$POD_RESOURCE_LIMIT -n $DEPLOY_PROJECT

#Nomeando porta 8080
oc patch dc/$APP_NAME -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'", "ports":[{"containerPort": 8080, "name":"http"}]}]}}}}' -n $DEPLOY_PROJECT

#Nomeando porta 8443
oc patch dc/$APP_NAME -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'", "ports":[{"containerPort": 8443, "name":"https"}]}]}}}}' -n $DEPLOY_PROJECT

#Nomeando porta 8888
oc patch dc/$APP_NAME -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'", "ports":[{"containerPort": 8888, "name":"ping"}]}]}}}}' -n $DEPLOY_PROJECT

#Nomeando porta 8778. Importante para que seja exibido o Java Console.
oc patch dc/$APP_NAME -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'", "ports":[{"containerPort": 8778, "name":"jolokia"}]}]}}}}' -n $DEPLOY_PROJECT

#Comando básico para criação da rota
CREATE_ROUTE_COMMAND="oc create route edge $APP_NAME -n $DEPLOY_PROJECT --service=$APP_NAME --hostname=$ROUTE_HOSTNAME --path=/$WAR_NAME --insecure-policy=Redirect"

#Executando comando de criação de rota
eval $CREATE_ROUTE_COMMAND

#Configurando timeout do router para 5 minutos
oc annotate route/$APP_NAME --overwrite haproxy.router.openshift.io/timeout=5m -n $DEPLOY_PROJECT

#Criando service para discovery no cluster
oc create service clusterip $APP_NAME-ping --clusterip="None" --tcp=8888:8888 -n $DEPLOY_PROJECT

#Alterando o seletor do service para bater com o nome da aplicação
oc patch svc/$APP_NAME-ping -p '{"spec":{"selector": {"app":"'$APP_NAME'", "deploymentconfig":"'$APP_NAME'"}}}' -n $DEPLOY_PROJECT

#Alterando o label app do service para bater com o nome da aplicação
oc label svc/$APP_NAME-ping app=$APP_NAME --overwrite -n $DEPLOY_PROJECT

#Configuração service do cluster discory para aceitar unready pods
oc annotate svc/$APP_NAME-ping --overwrite service.alpha.kubernetes.io/tolerate-unready-endpoints=true -n $DEPLOY_PROJECT

#Aumentando a quantidade de PODs de zero para 1 afim de subir a aplicação
oc scale --replicas=1 dc/$APP_NAME -n $DEPLOY_PROJECT
