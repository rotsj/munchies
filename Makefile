.PHONY: test build verify deploy clean

test:
	swift test --only-use-versions-from-resolved-file

build:
	./build.sh

verify: test build
	npm run test:browser

deploy: build
	npx --yes wrangler@4.156.2 pages deploy dist --project-name munchies

clean:
	rm -rf dist .build
