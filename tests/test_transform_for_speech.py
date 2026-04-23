import importlib.util
import os
import pathlib
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "bin" / "transform-for-speech.py"
SPEC = importlib.util.spec_from_file_location("transform_for_speech", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TransformForSpeechTest(unittest.TestCase):
    def setUp(self):
        self.config_path = pathlib.Path("/tmp/claude-voice-config")
        self.original_config = self.config_path.read_text(encoding="utf-8") if self.config_path.exists() else None
        self.write_config()
        MODULE.clear_cache()

    def tearDown(self):
        MODULE.clear_cache()
        if self.original_config is None:
            try:
                self.config_path.unlink()
            except FileNotFoundError:
                pass
        else:
            self.config_path.write_text(self.original_config, encoding="utf-8")

    def write_config(self, *, summary: str = "on", code: str = "silent") -> None:
        self.config_path.write_text(f"summary={summary}\ncode={code}\n", encoding="utf-8")

    def render(self, text: str, *, summary: str = "on", code: str = "silent") -> str:
        self.write_config(summary=summary, code=code)
        return MODULE.final_polish(MODULE.process_input(text))

    def test_paths_and_filenames(self):
        output = self.render("See `cmd/skip-listener/main.swift` and config.json.", code="narrate")
        self.assertIn("cmd slash skip listener slash main swift file", output)
        self.assertIn("config json file", output)

    def test_flags_env_vars_and_versions(self):
        output = self.render("Run --dry-run with $OPENAI_API_KEY on v2.5.1 at 12:30.", code="narrate")
        self.assertIn("dash dash dry run", output)
        self.assertIn("OPENAI API KEY environment variable", output)
        self.assertIn("version 2 dot 5 dot 1", output)
        self.assertIn("12 30", output)

    def test_code_silent_hides_non_doc_file_references(self):
        output = self.render("See `cmd/skip-listener/main.swift` and config.json.")
        self.assertIn("skip listener implementation", output)
        self.assertIn("configuration", output)
        self.assertNotIn("cmd slash skip listener slash main swift file", output)
        self.assertNotIn("config json file", output)

    def test_code_silent_keeps_internal_doc_names(self):
        output = self.render(
            "Review `docs/plans/active/ELLE_VM_Codex_Integration_Plan.md` and ELLE_Skip_Listener_App_Bundle_Plan.md."
        )
        self.assertIn("El Lee VM Codex Integration Plan markdown file", output)
        self.assertIn("El Lee Skip Listener App Bundle Plan markdown file", output)
        self.assertNotIn("docs slash plans slash active", output)

    def test_summary_mode_compresses_file_heavy_sentence(self):
        output = self.render(
            "I updated ELLE_Skip_Listener_App_Bundle_Plan.md and ELLE_Voice_TTS_Reference.md."
        )
        self.assertIn("Updated 2 El Lee markdown docs.", output)
        self.assertNotIn("Skip Listener App Bundle Plan", output)
        self.assertNotIn("Voice TTS Reference", output)

    def test_code_silent_summarizes_inline_commands(self):
        output = self.render("Run `python3 /Users/demo/.claude/plugins/claude-code-tts/tests/test_transform_for_speech.py`.")
        self.assertIn("python code - test transform for speech", output)
        self.assertNotIn("Users slash demo", output)

    def test_code_silent_preserves_numeric_inline_references(self):
        output = self.render("CI `#537` failed before PR `#248`, while commit `cdb55310` was already under review.")
        self.assertIn("CI 537 failed before PR 248", output)
        self.assertIn("commit cdb55310", output)
        self.assertNotIn("implementation detail", output)

    def test_code_silent_summarizes_fenced_code_blocks(self):
        output = self.render("```swift\nlet x = 1\n```")
        self.assertIn("swift snippet that sets x.", output)

    def test_code_silent_summarizes_single_command_blocks(self):
        output = self.render("```bash\npython3 /Users/demo/.claude/plugins/claude-code-tts/tests/test_transform_for_speech.py\n```")
        self.assertIn("python code - test transform for speech", output)

    def test_code_silent_summarizes_react_like_blocks(self):
        output = self.render(
            "```tsx\n"
            "function Settings() {\n"
            "  const [searchParams] = useSearchParams()\n"
            "  useEffect(() => {\n"
            "    fetchData()\n"
            "  }, [])\n"
            "  return <div />\n"
            "}\n"
            "```"
        )
        self.assertIn("typescript jsx snippet that defines component Settings and uses React hooks.", output)

    def test_pronounces_elle_in_plain_text(self):
        output = self.render("ELLE should stay consistent in voice mode.")
        self.assertIn("El Lee should stay consistent in voice mode.", output)

    def test_urls_and_emails(self):
        output = self.render("Docs: https://github.com/openai/openai and team@openai.com")
        self.assertIn("github dot com slash openai slash openai", output)
        self.assertIn("team at openai dot com", output)

    def test_key_value_block(self):
        output = self.render("engine: openai\nopenai_voice: nova\nspeed: 300")
        self.assertIn("engine: openai.", output)
        self.assertIn("openai voice: nova.", output)
        self.assertIn("speed: 300.", output)

    def test_diff_block_summary(self):
        output = self.render(
            "diff --git a/cmd/skip-listener/main.swift b/cmd/skip-listener/main.swift\n"
            "@@ -1,2 +1,3 @@\n"
            "+new line\n"
            "-old line\n"
        )
        self.assertIn("Diff block", output)
        self.assertIn("1 additions and 1 deletions", output)

    def test_stack_trace_summary(self):
        output = self.render(
            "Traceback\n"
            "File \"/tmp/app.py\", line 10, in main\n"
            "at Runner.execute\n",
            code="narrate",
        )
        self.assertIn("Stack trace with 3 lines", output)
        self.assertIn("tmp slash app python file", output)

    def test_large_table_summary_and_cache(self):
        output = self.render(
            "| Service | Region | Status |\n"
            "|---------|--------|--------|\n"
            "| API | US-East | Running |\n"
            "| Web | US-East | Running |\n"
            "| DB | US-West | Running |\n"
            "| Cache | EU | Running |\n"
            "| Auth | US-East | Down |\n"
        )
        self.assertIn("Table with 5 rows across 3 columns", output)
        self.assertIn('Say "read rows" to hear every row in detail.', output)
        index_path = pathlib.Path(MODULE.CACHE_DIR) / "index.txt"
        self.assertTrue(index_path.exists())
        self.assertIn("table-", index_path.read_text(encoding="utf-8"))

    def test_large_list_summary_and_cache(self):
        output = self.render(
            "- Alpha component\n"
            "- Beta component\n"
            "- Gamma component\n"
            "- Delta component\n"
            "- Epsilon component\n"
            "- Zeta component\n"
        )
        self.assertIn("6 items. First three", output)
        self.assertIn('Say "read items" for the full list.', output)
        index_path = pathlib.Path(MODULE.CACHE_DIR) / "index.txt"
        self.assertTrue(index_path.exists())
        self.assertIn("list-", index_path.read_text(encoding="utf-8"))

    def test_summary_mode_compresses_file_reference_lists(self):
        output = self.render(
            "- ELLE_Audit_Summary.md\n"
            "- ELLE_Voice_TTS_Reference.md\n"
            "- ELLE_Skip_Listener_App_Bundle_Plan.md\n"
            "- ELLE_Codex_Claude_Cross_Check_Hooks_Plan.md\n"
            "- ELLE_Global_Automatic_Continuation_Instructions.md\n"
        )
        self.assertIn('5 El Lee markdown docs. Say "read items" for the full list.', output)
        self.assertNotIn("First three", output)


if __name__ == "__main__":
    unittest.main()
