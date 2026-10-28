# Reuse the established LS6 native tools; replace the complete Python engine
# runtime from the immutable, licensed source snapshot recorded in SOURCE.json.
FROM ghcr.io/in-for-disaster-analytics/nodeodx@sha256:734392f0f59f6a1f3dfd9a24f86371d4d6b3b7cfd74e389453b6978a8a739e10
USER root
COPY odx-source/opendm /code/opendm
COPY odx-source/stages /code/stages
COPY odx-source/run.py odx-source/run.sh odx-source/VERSION odx-source/settings.yaml /code/
RUN chmod 755 /code/run.sh /code/run.py
COPY odx-source/LICENSE odx-source/SOURCE.json /code/shared-release/
COPY odx-source/licenses /code/shared-release/licenses
COPY odx-source/tests/test_shared_submodel.py /code/tests/test_shared_submodel.py
COPY nodeodx-source /var/www
WORKDIR /code
RUN python3 -c 'import hashlib,json,pathlib; m=json.load(open("/code/shared-release/SOURCE.json")); names=[n for n in m["files"] if n.startswith(("opendm/","stages/")) or n in ("run.py","run.sh","VERSION","settings.yaml","tests/test_shared_submodel.py")]; assert all(hashlib.sha256(pathlib.Path("/code",n).read_bytes()).hexdigest()==m["files"][n] for n in names)'
RUN python3 -c 'from opendm import remote; from stages import odm_app; import importlib.metadata; assert remote.SHARED_SUBMODEL_V1 is True; assert remote.__file__=="/code/opendm/remote.py"; assert odm_app.__file__=="/code/stages/odm_app.py"; assert importlib.metadata.version("pyodm")=="1.5.12"; print("Runtime engine contract verified")' \
 && test -x /code/run.sh \
 && test -x /code/run.py \
 && /code/run.sh --help >/dev/null \
 && /code/run.py --help >/dev/null \
 && python3 -m unittest discover -s /code/tests -p test_shared_submodel.py
WORKDIR /var/www
RUN python3 -m unittest discover -s tests/shared_submodel \
 && bash -lc '. "$NVM_DIR/nvm.sh" && nvm use "$NODE_VERSION" && node -e '\''const p=require("./package.json");for(const n of Object.keys(p.dependencies))require.resolve(n)'\'' && node tests/shared_submodel/test_capability.js && node tests/shared_submodel/test_cancellation.js'
ENTRYPOINT ["/usr/bin/node", "/var/www/index.js"]
