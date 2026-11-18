"""Hermes plugin: webhook_text_only.

voice.auto_tts is on so Telegram voice notes get spoken replies, but the runner
applies that default to every chat without an explicit /voice mode, and each
webhook delivery has a fresh chat id, so webhook replies were synthesized too.
Wraps GatewayVoiceMixin._should_send_voice_reply to say no for the webhook platform.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def register(ctx) -> None:
    from gateway.run_voice import GatewayVoiceMixin

    orig = GatewayVoiceMixin._should_send_voice_reply
    if getattr(orig, "_webhook_text_only", False):
        return

    def wrapped(self, event, *args, **kwargs):
        if getattr(event.source.platform, "value", None) == "webhook":
            return False
        return orig(self, event, *args, **kwargs)

    wrapped._webhook_text_only = True
    GatewayVoiceMixin._should_send_voice_reply = wrapped
    logger.info("webhook_text_only: webhook replies will not be spoken")
