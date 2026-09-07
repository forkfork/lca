def analyze(files, parser):
    output = []
    for path, text in files:
        output.append((path, parser(text)))
    return output
