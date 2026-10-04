//go:build darwin || (!android && linux)
// +build darwin !android,linux

package sftp

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFileStatFromInfoAtime(t *testing.T) {
	f := filepath.Join(t.TempDir(), "f")
	require.NoError(t, os.WriteFile(f, nil, 0o644))
	at, mt := time.Unix(1000000000, 0), time.Unix(1500000000, 0)
	require.NoError(t, os.Chtimes(f, at, mt))
	fi, err := os.Stat(f)
	require.NoError(t, err)
	_, st := fileStatFromInfo(fi)
	assert.Equal(t, uint32(at.Unix()), st.Atime)
	assert.Equal(t, uint32(mt.Unix()), st.Mtime)
}
