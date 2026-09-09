; ======================================================
; Common package version.
;
; The first two components identify the package API/feature
; line.  The third component is the package build/revision and
; is bumped for fixes.  Every shipped utility prints this same
; value; utility-local feature histories are not banner versions.
; ======================================================

	IFNDEF	_VERSION_INC
	DEFINE	_VERSION_INC

	DEFINE PACKAGE_VERSION "0.3.0"

	ENDIF
