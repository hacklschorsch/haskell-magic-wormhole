#!/usr/bin/python
"""Exchange SPAKE2 keys and print out the session key.

This does the ``pake`` phase of the magic-wormhole client over stdin and
stdout. Once the SPAKE2 exchange is done, it prints the session key.

It sends its side of the exchange first and then expects the other side's.

The logic is a best-effort attempt to reproduce magic-wormhole's own. It might
be wrong.
"""
import argparse
import attr
import json
import sys

try:
    import wormhole
except ImportError as e:
    print "Could not find Magic Wormhole: %s" % (e,)
    sys.exit(0)

from wormhole import util
from spake2 import SPAKE2_Symmetric

wormhole  # Be still, pyflakes


@attr.s
class Params(object):
    code = attr.ib()
    app_id = attr.ib()
    side = attr.ib()

    @classmethod
    def from_json(cls, json_value):
        return cls(
            code=json_value['code'],
            appID=json_value['app_id'],
            side=json_value['side'],
        )


def main():
    parser = argparse.ArgumentParser(prog='version_exchange')
    parser.add_argument(
        '--code', dest='code', type=unicode,
        help='Password to use to connect to other side')
    parser.add_argument(
        '--side', dest='side', type=unicode,
        help='Identifier for this side of the exchange')
    parser.add_argument(
        '--app-id', dest='app_id', type=unicode,
        help='Identifier for the application')
    params = parser.parse_args(sys.argv[1:])
    transport = Transport(input_stream=sys.stdin, output_stream=sys.stdout)
    run_exchange(transport, params.code, params.app_id, params.side)


def run_exchange(transport, code, app_id, side):
    # Send the SPAKE2 message
    spake = SPAKE2_Symmetric(
        util.to_bytes(code), idSymmetric=util.to_bytes(app_id))
    outbound = spake.start()
    transport.send({
        'phase': u'pake',
        'body': util.bytes_to_hexstr(
            util.dict_to_bytes({
                'pake_v1': util.bytes_to_hexstr(outbound),
            })
        ),
        'side': side,
        'type': 'message',
    })

    # Receive SPAKE2 message
    pake_msg = transport.receive()
    inbound = util.hexstr_to_bytes(
        util.bytes_to_dict(
            util.hexstr_to_bytes(pake_msg['body'])
        )['pake_v1']
    )
    spake_key = spake.finish(inbound)
    print util.bytes_to_hexstr(spake_key)


@attr.s
class Transport(object):
    input_stream = attr.ib()
    output_stream = attr.ib()

    def send(self, json_value):
        self.output_stream.write(json.dumps(json_value))
        self.output_stream.write('\n')
        self.output_stream.flush()

    def receive(self):
        line = self.input_stream.readline()
        return json.loads(line.strip())


if __name__ == '__main__':
    main()
