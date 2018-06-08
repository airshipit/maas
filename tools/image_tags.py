#!/bin/python
# Copyright 2018 AT&T Intellectual Property.  All other rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import json
import logging
import os
import sys

LOG = logging.getLogger(__name__)

LOG_FORMAT = '%(asctime)s %(levelname)-8s %(name)s:%(funcName)s [%(lineno)3d] %(message)s'  # noqa


class TagGenExeception(Exception):
    pass


def read_config(stream, env):
    config = {}
    try:
        config['tags'] = json.load(stream)
    except ValueError:
        LOG.exception('Failed to decode JSON from input stream')
        config['tags'] = {}

    LOG.debug('Configuration after reading stream: %s', config)

    config['context'] = {
        'branch': env.get('BRANCH'),
        'change': env.get('CHANGE'),
        'commit': env.get('COMMIT'),
        'ps': env.get('PATCHSET'),
    }

    LOG.info('Final configuration: %s', config)

    return config


def build_tags(config):
    tags = config.get('tags', {}).get('static', [])
    LOG.debug('Dynamic tags: %s', tags)
    tags.extend(build_dynamic_tags(config))
    LOG.info('All tags: %s', tags)
    return tags


def build_dynamic_tags(config):
    dynamic_tags = []

    dynamic_tags.extend(_build_branch_tag(config))
    dynamic_tags.extend(_build_commit_tag(config))
    dynamic_tags.extend(_build_ps_tag(config))

    return dynamic_tags


def _build_branch_tag(config):
    if _valid_dg(config, 'branch'):
        return [config['context']['branch']]
    else:
        return []


def _build_commit_tag(config):
    if _valid_dg(config, 'commit'):
        return [config['context']['commit']]
    else:
        return []


def _build_ps_tag(config):
    if _valid_dg(config, 'patch_set', 'change') and _valid_dg(
            config, 'patch_set', 'ps'):
        return [
            '%s-%s' % (config['context']['change'], config['context']['ps'])
        ]
    else:
        return []


def _valid_dg(config, dynamic_tag, context_name=None):
    if context_name is None:
        context_name = dynamic_tag

    if config.get('tags', {}).get('dynamic', {}).get(dynamic_tag):
        if config.get('context', {}).get(context_name):
            return True
        else:
            raise TagGenExeception('Dynamic tag "%s" requested, but "%s"'
                                   ' not found in context' % (dynamic_tag,
                                                              context_name))
    else:
        return False


def main():
    config = read_config(sys.stdin, os.environ)
    tags = build_tags(config)

    for tag in tags:
        print(tag)


if __name__ == '__main__':
    logging.basicConfig(format=LOG_FORMAT, level=logging.WARNING)
    try:
        main()
    except TagGenExeception:
        LOG.exception('Failed to generate tags')
        sys.exit(1)
    except Exception:
        LOG.exception('Unexpected exception')
        sys.exit(2)
