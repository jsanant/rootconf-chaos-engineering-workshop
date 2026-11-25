# Runtime-only image. Binary is cross-compiled on the host by `make loadgen-build`
# so corporate MITM / poor network cannot break apk/go downloads inside the build.
FROM scratch
COPY loadgen /loadgen
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/loadgen"]
