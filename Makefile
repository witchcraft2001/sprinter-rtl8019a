.PHONY: build package image clean

build:
	tools/build.sh

package:
	tools/package.sh

image:
	tools/image.sh

clean:
	rm -rf build
	rm -f distr/sprinter-rtl8019a.zip distr/sprinter-rtl8019a.img
