# syntax=docker/dockerfile:1
# 多階段建置:Go binary 用 modernc.org/sqlite (純 Go,無 CGO),最終映像極小
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY go.sum* ./
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /server .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /server /app/server
ENV PORT=8080
ENV DB_PATH=/tmp/h-beam.db
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/server"]
