package com.mstsage.mimir;

import android.content.Context;
import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.webkit.WebView;

/**
 * WebView hosting the Chrome DevTools frontend. DevTools edits values in contenteditable fields,
 * which Android soft keyboards treat as rich text with composition and autocorrect; the inline
 * editor then never sees a committed value (typing "lags", edits don't apply). Ask the IME for
 * plain, suggestion-free input instead.
 */
public class DevToolsWebView extends WebView {
    public DevToolsWebView(Context ctx) { super(ctx); }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        InputConnection ic = super.onCreateInputConnection(outAttrs);
        if (ic != null) {
            outAttrs.inputType = (outAttrs.inputType & ~InputType.TYPE_TEXT_FLAG_AUTO_CORRECT & ~InputType.TYPE_TEXT_FLAG_AUTO_COMPLETE)
                    | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                    | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD;   // strongest "no composition" hint most IMEs honour
            outAttrs.imeOptions |= EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING;
        }
        return ic;
    }
}
