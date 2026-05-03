ENV_FILE := .hugo_version
COMPOSE  := docker compose --env-file $(ENV_FILE)

.PHONY: init dev build clean

init:
	$(COMPOSE) --profile init run --rm hugo-init

dev:
	$(COMPOSE) up

build:
	docker run --rm \
		-v "$$PWD/williamblack-dev:/project" \
		-u "$$(id -u):$$(id -g)" \
		"$$(grep '^HUGO_IMAGE=' $(ENV_FILE) | cut -d= -f2-)" \
		--minify

clean:
	rm -rf williamblack-dev/public williamblack-dev/resources
