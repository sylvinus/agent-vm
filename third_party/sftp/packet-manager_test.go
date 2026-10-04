package sftp

import (
	"encoding"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

type _testSender struct {
	sent chan encoding.BinaryMarshaler
}

func newTestSender() *_testSender {
	return &_testSender{make(chan encoding.BinaryMarshaler)}
}

func (s _testSender) sendPacket(p encoding.BinaryMarshaler) error {
	s.sent <- p
	return nil
}

type fakepacket struct {
	reqid uint32
	oid   uint32
}

func fake(rid, order uint32) fakepacket {
	return fakepacket{reqid: rid, oid: order}
}

func (fakepacket) MarshalBinary() ([]byte, error) {
	return make([]byte, 4), nil
}

func (fakepacket) UnmarshalBinary([]byte) error {
	return nil
}

func (f fakepacket) id() uint32 {
	return f.reqid
}

type pair struct {
	in, out fakepacket
}

type orderedPair struct {
	in  orderedRequest
	out orderedResponse
}

// basic test
var ttable1 = []pair{
	{fake(0, 0), fake(0, 0)},
	{fake(1, 1), fake(1, 1)},
	{fake(2, 2), fake(2, 2)},
	{fake(3, 3), fake(3, 3)},
}

// outgoing packets out of order
var ttable2 = []pair{
	{fake(10, 0), fake(12, 2)},
	{fake(11, 1), fake(11, 1)},
	{fake(12, 2), fake(13, 3)},
	{fake(13, 3), fake(10, 0)},
}

// request ids are not incremental
var ttable3 = []pair{
	{fake(7, 0), fake(7, 0)},
	{fake(1, 1), fake(1, 1)},
	{fake(9, 2), fake(3, 3)},
	{fake(3, 3), fake(9, 2)},
}

// request ids are all the same
var ttable4 = []pair{
	{fake(1, 0), fake(1, 0)},
	{fake(1, 1), fake(1, 1)},
	{fake(1, 2), fake(1, 3)},
	{fake(1, 3), fake(1, 2)},
}

var tables = [][]pair{ttable1, ttable2, ttable3, ttable4}

func TestPacketManager(t *testing.T) {
	sender := newTestSender()
	s := newPktMgr(sender)

	for i := range tables {
		table := tables[i]
		orderedPairs := make([]orderedPair, 0, len(table))
		for _, p := range table {
			orderedPairs = append(orderedPairs, orderedPair{
				in:  orderedRequest{p.in, p.in.oid},
				out: orderedResponse{p.out, p.out.oid},
			})
		}
		for _, p := range orderedPairs {
			s.incomingPacket(p.in)
		}
		for _, p := range orderedPairs {
			s.readyPacket(p.out)
		}
		for _, p := range table {
			pkt := <-sender.sent
			id := pkt.(orderedResponse).id()
			assert.Equal(t, id, p.in.id())
		}
	}
	s.close()
}

func (p sshFxpRemovePacket) String() string {
	return fmt.Sprintf("RmPkt:%d", p.ID)
}
func (p sshFxpOpenPacket) String() string {
	return fmt.Sprintf("OpPkt:%d", p.ID)
}
func (p sshFxpWritePacket) String() string {
	return fmt.Sprintf("WrPkt:%d", p.ID)
}
func (p sshFxpClosePacket) String() string {
	return fmt.Sprintf("ClPkt:%d", p.ID)
}

// A slow WRITE must still run before the WRITE and the FSETSTAT sent after it.
func TestPacketManagerSequential(t *testing.T) {
	sender := newTestSender()
	s := newPktMgr(sender)
	s.sequential = true
	var mu sync.Mutex
	var done []uint32
	runWorker := func(ch chan orderedRequest) {
		go func() {
			for pkt := range ch {
				if pkt.id() == 1 {
					time.Sleep(50 * time.Millisecond)
				}
				mu.Lock()
				done = append(done, pkt.id())
				mu.Unlock()
				s.readyPacket(s.newOrderedResponse(&sshFxpStatusPacket{ID: pkt.id()}, pkt.orderID()))
			}
		}()
	}
	pktChan := s.workerChan(runWorker)
	for _, p := range []requestPacket{&sshFxpWritePacket{ID: 1}, &sshFxpWritePacket{ID: 2}, &sshFxpFsetstatPacket{ID: 3}} {
		pktChan <- s.newOrderedRequest(p)
	}
	for range 3 {
		<-sender.sent
	}
	close(pktChan)
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, []uint32{1, 2, 3}, done)
}
