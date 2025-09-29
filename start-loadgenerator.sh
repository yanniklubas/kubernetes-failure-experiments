#!/usr/bin/env bash

docker compose --file "$HOME/kubernetes-failure-experiments/load-generator/tools.descartes.dlim.httploadgenerator/docker/out.yml" up --force-recreate --wait --build
