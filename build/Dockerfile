FROM bitnami/kubectl:latest

USER root
RUN curl -sL "https://github.com/mikefarah/yq/releases/download/v4.9.3/yq_linux_amd64" > /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

USER 1001

COPY --chown=1001:1001 kommandeer.sh /
COPY --chown=1001:1001 pvc-template.json /
COPY --chown=1001:1001 build-pvc.jq /
RUN chmod u+x /kommandeer.sh

ENTRYPOINT [ "/kommandeer.sh" ]
