bool i;

int main()
{
  int i; # Should hide the global i

  i = 42;
  printi(i + i);
  return 0;
}
