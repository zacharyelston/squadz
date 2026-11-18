module github.com/zacharyelston/squadz/server

go 1.26.0

require github.com/zacharyelston/pairkit/go v0.0.0

require rsc.io/qr v0.2.0 // indirect

// PairKit has no published version yet: build with it checked out next to
// this repository (../../pairkit).
replace github.com/zacharyelston/pairkit/go => ../../pairkit/go
