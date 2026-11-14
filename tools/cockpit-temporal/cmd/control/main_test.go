package main

import "testing"

func TestValidation(t *testing.T) {
	good := request{Address: "127.0.0.1:7233", WorkflowID: "run", Action: "control", Command: "stop"}
	if err := validate(good); err != nil {
		t.Fatal(err)
	}
	cases := []request{good, good, good, good}
	cases[0].Address = "example.com:7233"
	cases[1].WorkflowID = ""
	cases[2].Action = "delete"
	cases[3].Command = "arbitrary"
	for _, c := range cases {
		if validate(c) == nil {
			t.Fatalf("accepted %+v", c)
		}
	}
}
