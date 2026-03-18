#!/usr/bin/env python3
"""Generate and sign MacBridge shortcut files for Notes AppIntents."""

import os
import plistlib
import sys
import uuid

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shortcuts")


def new_uuid():
    return str(uuid.uuid4()).upper()


# -- Building blocks --

def detect_dict():
    uid = new_uuid()
    return uid, {
        "WFWorkflowActionIdentifier": "is.workflow.actions.detect.dictionary",
        "WFWorkflowActionParameters": {
            "WFInput": {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"},
            "UUID": uid,
        },
    }


def get_key(dict_uuid, key):
    uid = new_uuid()
    return uid, {
        "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
        "WFWorkflowActionParameters": {
            "WFInput": {
                "Value": {"OutputUUID": dict_uuid, "Type": "ActionOutput", "OutputName": "Dictionary"},
                "WFSerializationType": "WFTextTokenAttachment",
            },
            "WFDictionaryKey": key,
            "UUID": uid,
        },
    }


def find_notes_by_name(name_action_uuid):
    """Find Notes action that resolves a note name string into a NoteEntity."""
    uid = new_uuid()
    return uid, {
        "WFWorkflowActionIdentifier": "is.workflow.actions.filter.notes",
        "WFWorkflowActionParameters": {
            "WFContentItemFilter": {
                "Value": {
                    "WFActionParameterFilterPrefix": 1,
                    "WFContentPredicateBoundedDate": False,
                    "WFActionParameterFilterTemplates": [
                        {
                            "Operator": 4,
                            "Values": {
                                "Value": {
                                    "Type": "ActionOutput",
                                    "OutputUUID": name_action_uuid,
                                    "OutputName": "Dictionary Value",
                                },
                                "WFSerializationType": "WFTextTokenAttachment",
                            },
                            "Property": "Name",
                            "Removable": True,
                        }
                    ],
                },
                "WFSerializationType": "WFContentPredicateTableTemplate",
            },
            "WFContentItemSortOrder": "Latest First",
            "WFContentItemSortProperty": "WFItemModificationDate",
            "WFContentItemLimitEnabled": True,
            "WFContentItemLimitNumber": 1,
            "UUID": uid,
        },
    }


def text_token(action_uuid, output_name="Dictionary Value"):
    return {
        "Value": {
            "string": "\ufffc",
            "attachmentsByRange": {
                "{0, 1}": {"OutputUUID": action_uuid, "Type": "ActionOutput", "OutputName": output_name}
            },
        },
        "WFSerializationType": "WFTextTokenString",
    }


def action_ref(action_uuid, output_name="Dictionary Value"):
    return {
        "Value": {"OutputUUID": action_uuid, "Type": "ActionOutput", "OutputName": output_name},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def notes_intent(intent_name, params):
    return {
        "WFWorkflowActionIdentifier": "com.apple.mobilenotes.SharingExtension",
        "WFWorkflowActionParameters": {
            "AppIntentDescriptor": {
                "TeamIdentifier": "0000000000",
                "BundleIdentifier": "com.apple.Notes",
                "Name": "Notes",
                "AppIntentIdentifier": intent_name,
            },
            "OpenWhenRun": False,
            "UUID": new_uuid(),
            **params,
        },
    }


def make_shortcut(actions):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2702.0.4",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59771, "WFWorkflowIconStartColor": 4282601983},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
    }


# -- Shortcut definitions --
# Each shortcut accepts JSON string input via Shortcuts Events AppleScript.
# Shortcuts that operate on existing notes use "Find Notes" to resolve
# a note name into a NoteEntity (required by Notes AppIntents).

def build_all():
    shortcuts = {}

    # 1. Create Note from Markdown
    # Input: {"name": "...", "content": "markdown...", "folder": "..."}
    d, detect = detect_dict()
    nm, get_name = get_key(d, "name")
    c, get_content = get_key(d, "content")
    f, get_folder = get_key(d, "folder")
    md_uid = new_uuid()
    shortcuts["MacBridge - Notes Create Markdown"] = make_shortcut([
        detect, get_name, get_content, get_folder,
        {"WFWorkflowActionIdentifier": "is.workflow.actions.getrichtextfrommarkdown",
         "WFWorkflowActionParameters": {"WFInput": action_ref(c), "UUID": md_uid}},
        notes_intent("CreateNoteLinkAction", {
            "name": text_token(nm),
            "WFCreateNoteInput": text_token(md_uid, "Rich Text from Markdown"),
            "folder": action_ref(f),
        }),
    ])

    # 2. Append Markdown to Note
    # Input: {"noteName": "...", "markdown": "..."}
    d, detect = detect_dict()
    n, get_name = get_key(d, "noteName")
    m, get_md = get_key(d, "markdown")
    fn, find = find_notes_by_name(n)
    shortcuts["MacBridge - Notes Append Markdown"] = make_shortcut([
        detect, get_name, get_md, find,
        notes_intent("AppendMarkdownToNoteLinkAction", {
            "entity": action_ref(fn, "Notes"),
            "markdownText": text_token(m),
        }),
    ])

    # 3. Add Checklist Item
    # Input: {"noteName": "...", "text": "..."}
    d, detect = detect_dict()
    t, get_text = get_key(d, "text")
    n, get_name = get_key(d, "noteName")
    fn, find = find_notes_by_name(n)
    shortcuts["MacBridge - Notes Add Checklist Item"] = make_shortcut([
        detect, get_text, get_name, find,
        notes_intent("CreateChecklistItemLinkAction", {
            "name": text_token(t),
            "noteEntity": action_ref(fn, "Notes"),
        }),
    ])

    # Tags are handled via JXA (#hashtag body append), no shortcut needed.

    # 4. Add Table
    # Input: {"noteName": "...", "csv": "a,b\n1,2", "name": "Table Name"}
    d, detect = detect_dict()
    n, get_name = get_key(d, "noteName")
    c, get_csv = get_key(d, "csv")
    tn, get_tname = get_key(d, "name")
    fn, find = find_notes_by_name(n)
    shortcuts["MacBridge - Notes Add Table"] = make_shortcut([
        detect, get_name, get_csv, get_tname, find,
        notes_intent("CreateTableLinkAction", {
            "note": action_ref(fn, "Notes"),
            "csvString": text_token(c),
            "name": text_token(tn),
        }),
    ])

    # 7. Pin Notes
    # Input: {"noteName": "..."}
    d, detect = detect_dict()
    n, get_name = get_key(d, "noteName")
    fn, find = find_notes_by_name(n)
    shortcuts["MacBridge - Notes Pin"] = make_shortcut([
        detect, get_name, find,
        notes_intent("PinNotesLinkAction", {
            "entities": action_ref(fn, "Notes"),
            "operation": 0,
        }),
    ])

    # 8. Unpin Notes
    # Input: {"noteName": "..."}
    d, detect = detect_dict()
    n, get_name = get_key(d, "noteName")
    fn, find = find_notes_by_name(n)
    shortcuts["MacBridge - Notes Unpin"] = make_shortcut([
        detect, get_name, find,
        notes_intent("PinNotesLinkAction", {
            "entities": action_ref(fn, "Notes"),
            "operation": 1,
        }),
    ])

    return shortcuts


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    shortcuts = build_all()

    for name, data in shortcuts.items():
        # Signed file gets the clean name (this becomes the shortcut name on import)
        unsigned = os.path.join(OUTPUT_DIR, f"{name}_unsigned.shortcut")
        signed = os.path.join(OUTPUT_DIR, f"{name}.shortcut")

        with open(unsigned, "wb") as f:
            plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

        ret = os.system(f'shortcuts sign -m anyone -i "{unsigned}" -o "{signed}" 2>/dev/null')
        if ret != 0:
            print(f"  FAIL: {name}")
            sys.exit(1)

        os.remove(unsigned)
        print(f"  OK: {name}")

    print(f"\n{len(shortcuts)} shortcuts generated in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
