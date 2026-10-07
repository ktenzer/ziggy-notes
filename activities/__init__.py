"""Ziggy Notes activities."""

from activities.analysis import analyze_conversation
from activities.capture import capture_audio
from activities.gdoc import create_google_doc
from activities.identity import identify_speakers
from activities.summary import summarize_meeting

ALL_ACTIVITIES = [
    capture_audio,
    analyze_conversation,
    identify_speakers,
    summarize_meeting,
    create_google_doc,
]

__all__ = [
    "capture_audio",
    "analyze_conversation",
    "identify_speakers",
    "summarize_meeting",
    "create_google_doc",
    "ALL_ACTIVITIES",
]
