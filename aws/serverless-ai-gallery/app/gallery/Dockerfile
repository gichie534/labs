# Multi-stage build: compile the static server, then ship it on a minimal distroless image.
# Cross-compile to the target arch (defaults to amd64 to match the Fargate tasks).
FROM golang:1.23 AS build
WORKDIR /src
COPY . .
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} go build -o /server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /server /server
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/server"]
