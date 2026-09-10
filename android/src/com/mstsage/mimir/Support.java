package com.mstsage.mimir;

import android.app.Activity;

/**
 * Tip-jar backend. The Play Billing implementation (BillingSupport, in android/src-billing) is
 * compiled only by the Gradle build; the pure-Ruby pipeline ships without it. Loaded by name so
 * MainActivity compiles either way. All results are reported to Ruby as events:
 *   billing.ready {products:[{id,title,price}]} | billing.unavailable {reason}
 *   billing.purchased {product} | billing.error {text}
 */
public interface Support {
    void connect(Activity activity, RubyRuntime ruby);
    void query();
    void buy(Activity activity, String productId);
    void destroy();

    static Support create() {
        try {
            return (Support) Class.forName("com.mstsage.mimir.BillingSupport").getDeclaredConstructor().newInstance();
        } catch (Throwable t) {
            return new Support() {
                RubyRuntime ruby;
                public void connect(Activity a, RubyRuntime r) { ruby = r; }
                public void query() { if (ruby != null) ruby.event("billing.unavailable", "reason", "This build has no Play Billing"); }
                public void buy(Activity a, String id) { query(); }
                public void destroy() {}
            };
        }
    }
}
